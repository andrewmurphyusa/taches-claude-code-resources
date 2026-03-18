# Improvements to make to Ralph:

## 1. Fix bug: plan mode (and maybe decompose mode) not ending when no further changes are required.

- Plan mode doesn't stop when no further planning is required (once, when it ran out of capacity, it looped nearly 1000 times).  
- make it stop if it detects "no further changes are required" already in the plan file
- make it stop when it determines that no further changes are required.

- check decompose mode for the same bug, and add stop conditions there if necessary

## 2. Fix bug: decompose mode doesn't log to ralph.log ???

Running "tail -f ralph.log", ran decompose, it decomposed tasks but nothing was logged to ralph.log!

## 3. Fix bug: the task it *says* it's doing next/now isn't what it actually *picks to do* 

This one is a bit bigger to fix, because it requires identifying the actual next task to work on in a separate place from the step that actually picks the next task, using the same logic.  It might be better to have it create a separate "NEXT-TASK.md" file, and populate that file from the orchestrator and pick it up in the ralph script

## 4. Add iteration limits to plan and decompose modes.

- plan & decompose modes currently do not have any iteration limiting
- have them respect the iteration limits

## 5. Add "preferred" and "fallback" models (one for Claude, one for Codex)

- Each task should have a "preferred" model and a "fallback" model
- one should be Claude and one should be Codex (although neither is mandatory primary i.e. different task can *prefer* one over the other)
- check capacity on the *primary*; if there is no capacity available there then check secondary; only sleep if *both* do not have capacity
- sleep for the minimum amount of time required for *one* of them to become available
- could get capacity for both, then check primary-then-secondary, then do sleep-until-capacity-available

## 6. Could - remove iterations from ralph.sh entirely since it doesn't actually do them any more.

## 7. Add "--stop-after" parameter(s)

- add parameter(s) to limit the *clock time* that iterations will run until.
- either have one parameter "--stop-after" which is a time OR a date-and-time
-- or have "--stop-after-date" and "--stop-after-time" which are date & time respectively, and have it combine those 2 parameters to set the complete stop time
-- if only time is provided, then check whether the script start time is after that time
    - if no, then use the current date for the stop date
    - if yes, then use tomorrow for the stop date
- absolute stop time is stop-date + stop-time
- at start of each iteration, check whether the current date+time is after the stop date+time
    - if yes then break out of iteration loop and stop


