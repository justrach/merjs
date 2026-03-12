Top 5 at the first OpenAI hackathon in Singapore last weekend!!

Yu Xi Lim and I built our project in under 30 minutes. You'd see how in a bit — it basically built itself.

We called it codedb at the hackathon. Here's what it does.

One prompt. Working app. A roadmap for what to build next. PRs already open for review.

Not "here's some boilerplate to get you started." Multiple Codex agents and subagents get spawned, they explore every possible way to build it, review each other's code, and hand you the strongest version. Then they keep going: here's what's next, here are the tickets, here are the pull requests. Ready to review, not ready to start.

We've since renamed it devswarm — because that's exactly what it does.

The way it works is pretty simple. You give it a goal. The orchestrator decomposes it into a task graph and launches up to 100 agents on real OS threads, scaling with your CPU. They fan out: one group writes code, another reviews it, another traces execution paths, another explores architecture choices — all at the same time. Findings land in a shared memory store that survives context compression so nothing gets lost. The synthesis agent reads every branch, kills the dead ends, and produces the strongest solution.

The bit that gets me: devswarm *built itself*. We pointed it at its own codebase mid-hackathon and it closed its own bugs, opened its own PRs, and shipped its own features. The repo you're looking at is partly a product of the tool itself. It's still going — those pushes are live:
→ https://lnkd.in/gvqzJHEk
→ https://lnkd.in/gJxBep3b

And the issues that follow show exactly where this is going:
- Agent fitness scoring: track which agents produce the strongest outputs, weight them higher in future runs
- Cross-generation learning: winning strategies from one swarm inform the next
- Self-improving prompts: meta-agents that review and rewrite the system's own instructions
- Population-based search: multiple swarm generations compete, survivors seed the next
- Automated benchmarking: agents define their own success metrics and optimise against them

Evolutionary search applied to software development. Each run makes the next one smarter.

Sub-1 MB binary. Written in Zig. Works with Codex, Claude Code, or any MCP client. Download it from the releases on GitHub: https://lnkd.in/g8auAVZy

You really can just build things ig (v0.0.2 has a lot more subagents and task decomposition tools than the hackathon version!)

Thanks to Gabriel Chua, OpenAI, OpenAIDevs, Brian Chew, and the team at Lorong AI for organising — and Ivan Leo, Agrim Singh, and everyone at 65 Labs for making it so fun.

#zig #mcp #ai #swarm #claudecode #devtools #hackathon #opensource
