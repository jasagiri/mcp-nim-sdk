## How fast one sender may make requests: a token bucket per sender, held in
## a table that has a size.
##
## A bucket holds up to one second's worth of requests and fills at the
## allowed rate, so a short burst passes and a sustained flood does not. The
## table never grows past `maxSenders`: a sender that has been quiet long
## enough to have a full bucket again is not worth remembering, and when none
## is that quiet the one quiet longest is forgotten, which gives it a full
## allowance again. A sender that cycles through identities can therefore
## outrun the limit only as fast as it can make the transport accept new
## ones (sessions are limited there).

import std/[monotimes, tables, times]

type
  Bucket = object
    tokens: float
    stamp: MonoTime
    refusing: bool

  RateLimiter* = ref object
    buckets: Table[string, Bucket]

  Verdict* = object
    allowed*: bool
    retryAfterMs*: int
      ## When refused: how long until a request would be allowed.
    firstRefusal*: bool
      ## When refused: this is the first refusal since the sender last had
      ## its full allowance, so a log line about it does not repeat for a
      ## flood.

func newRateLimiter*(): RateLimiter {.raises: [].} =
  RateLimiter(buckets: initTable[string, Bucket]())

func sendersKnown*(limiter: RateLimiter): int {.raises: [].} =
  limiter.buckets.len

func filled(bucket: Bucket, now: MonoTime, perSecond: int): float {.raises: [].} =
  let seconds = (now - bucket.stamp).inNanoseconds.float / 1e9
  min(perSecond.float, bucket.tokens + seconds * perSecond.float)

proc makeRoom(limiter: RateLimiter, now: MonoTime, perSecond, maxSenders: int) =
  ## Room for one more sender: forget the ones that are full again, and if
  ## that frees nothing, the one quiet longest.
  var quiet: seq[string]
  for key, bucket in limiter.buckets:
    if bucket.filled(now, perSecond) >= perSecond.float:
      quiet.add key
  for key in quiet:
    limiter.buckets.del(key)
  while limiter.buckets.len >= maxSenders:
    var oldest = ""
    var oldestStamp = now
    for key, bucket in limiter.buckets:
      if oldest.len == 0 or bucket.stamp < oldestStamp:
        oldest = key
        oldestStamp = bucket.stamp
    limiter.buckets.del(oldest)

proc take*(limiter: RateLimiter, sender: string, perSecond, maxSenders: int,
           now = getMonoTime()): Verdict =
  ## Whether `sender` may make a request now; takes the request's token when
  ## it may. `perSecond` must be above 0 (0 means no limit, which the caller
  ## decides) and `maxSenders` above 0.
  doAssert perSecond > 0 and maxSenders > 0, "a rate limit needs a positive rate and table size"
  if not limiter.buckets.hasKey(sender):
    if limiter.buckets.len >= maxSenders:
      limiter.makeRoom(now, perSecond, maxSenders)
    limiter.buckets[sender] = Bucket(tokens: perSecond.float, stamp: now)
  var bucket = limiter.buckets[sender]
  bucket.tokens = bucket.filled(now, perSecond)
  bucket.stamp = now
  if bucket.tokens >= perSecond.float:
    # Not when a request passes: a sender that keeps sending gets one through
    # now and then, and each would start the record of its flood anew.
    bucket.refusing = false
  if bucket.tokens >= 1.0:
    bucket.tokens -= 1.0
    limiter.buckets[sender] = bucket
    return Verdict(allowed: true)
  let first = not bucket.refusing
  bucket.refusing = true
  limiter.buckets[sender] = bucket
  Verdict(allowed: false, firstRefusal: first,
          retryAfterMs: int((1.0 - bucket.tokens) / perSecond.float * 1000.0) + 1)
