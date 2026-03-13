# Improvements to make to Ralph:

## 1. Fix bug: plan mode (and maybe decompose mode) not ending when no further changes are required.

- Plan mode doesn't stop when no further planning is required (once, when it ran out of capacity, it looped nearly 1000 times).  
- make it stop if it detects "no further changes are required" already in the plan file
- make it stop when it determines that no further changes are required.

- check decompose mode for the same bug, and add stop conditions there if necessary

## 2. Add iteration limits to plan and decompose modes.

- plan & decompose modes currently do not have any iteration limiting
- have them respect the iteration limits

## 3. Add "--stop-after" parameter(s)

- add parameter(s) to limit the *clock time* that iterations will run until.
- either have one parameter "--stop-after" which is a time OR a date-and-time
-- or have "--stop-after-date" and "--stop-after-time" which are date & time respectively, and have it combine those 2 parameters to set the complete stop time
-- if only time is provided, then check whether the script start time is after that time
    - if no, then use the current date for the stop date
    - if yes, then use tomorrow for the stop date
- absolute stop time is stop-date + stop-time
- at start of each iteration, check whether the current date+time is after the stop date+time
    - if yes then break out of iteration loop and stop


