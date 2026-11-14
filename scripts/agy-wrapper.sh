#!/usr/bin/env bash
exec nix shell github:numtide/llm-agents.nix#antigravity-cli -c agy "$@"
