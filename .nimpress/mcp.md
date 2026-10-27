---
title: MCP server and steps
description: What the smig mcp server serves, its run page, and the steps a migration run reports.
visibility: hidden
tags: smig, mcp, steps, step stream, run page
lastUpdated: true
---

## The server

`smig mcp` serves smig over stdio through nimbody's `cli.MCPCommand`. Every command is a tool except `mcp`, `skill`, `plugin`, `completion`, `help` and `version`, and each tool is annotated read, write or destructive. The run page is `ui://smig/run`.

## Steps

Applying migrations reports one step per applied file, with the file path as the step id. A step is `running` before the file runs, then `done` with its duration or `failed` with the error. Steps are reported only under a tool run, `stream.Machine()`, because in a terminal smig prints its own progress.
