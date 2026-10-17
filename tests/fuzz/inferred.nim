## Shared by the fuzzing targets.

template inferred*(body: untyped) =
  ## Runs a proc whose raises list the compiler infers as `Exception` (it
  ## recurses) under this file's `raises: [CatchableError]`. A defect and a
  ## catchable error pass through as they are; there is nothing else.
  try:
    body
  except CatchableError as e:
    raise e
  except Defect as e:
    raise e
  except Exception as e:
    raise newException(CatchableError, "neither catchable nor a defect: " & e.msg)
