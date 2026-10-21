# Task group lowering and protected cleanup

## Plan

`agents/plans/2026-10-20-017-task-group-lowering.md`

## Summary

`async with` lowers to loop's group helpers through a Try whose exit replaces
the departure. Async functions protect `finally` clauses and resource exits by
clearing the task's scope. Task groups run end to end, and the interim
diagnostic is gone. The plan's goal is met.

## Checks run

- `make test`: 367 passed, 0 failed.

## Manual verification

1. With protection disabled in lowering, `task_groups.wlo` loses the cleanup
   lines that await after a stop. This confirms the test exercises protection.
