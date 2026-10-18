## Dates and times as RFC 3339 writes them (section 5.6): a date is
## YYYY-MM-DD and names a day that exists; a date-time adds T, HH:MM:SS with
## an optional fraction, and Z or an offset. A year has four digits and no
## sign.

import std/[strutils, times]

func isDate*(text: string): bool =
  ## YYYY-MM-DD naming a day that exists.
  if text.len != 10 or text[4] != '-' or text[7] != '-':
    return false
  for i in [0, 1, 2, 3, 5, 6, 8, 9]:
    if text[i] notin Digits:
      return false
  let year = parseInt(text[0 .. 3])
  let month = parseInt(text[5 .. 6])
  let day = parseInt(text[8 .. 9])
  month in 1 .. 12 and day in 1 .. getDaysInMonth(Month(month), year)

func isDateTime*(text: string): bool =
  ## RFC 3339: a date, T, HH:MM:SS with optional fraction, and Z or an offset.
  let t = text.find({'T', 't'})
  if t != 10 or not isDate(text[0 ..< t]):
    return false
  let time = text[t + 1 .. ^1]
  if time.len < 9:
    return false
  for i in [0, 1, 3, 4, 6, 7]:
    if time[i] notin Digits:
      return false
  if time[2] != ':' or time[5] != ':':
    return false
  if parseInt(time[0 .. 1]) > 23 or parseInt(time[3 .. 4]) > 59 or
     parseInt(time[6 .. 7]) > 60:
    return false
  var rest = time[8 .. ^1]
  if rest.len > 0 and rest[0] == '.':
    var digits = 0
    while digits + 1 < rest.len and rest[digits + 1] in Digits:
      inc digits
    if digits == 0:
      return false
    rest = rest[digits + 1 .. ^1]
  if rest in ["Z", "z"]:
    return true
  rest.len == 6 and rest[0] in {'+', '-'} and rest[3] == ':' and
    rest[1] in Digits and rest[2] in Digits and rest[4] in Digits and
    rest[5] in Digits and parseInt(rest[1 .. 2]) <= 23 and parseInt(rest[4 .. 5]) <= 59
