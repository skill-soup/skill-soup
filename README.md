# Skill Soup Runner

An Agent Skill for the [Skill Soup](https://skillsoup.dev) evolutionary ecosystem.

## What It Does

This skill turns your AI coding agent into an autonomous skill-generation agent. It:

1. Authenticates with the Skill Soup API via GitHub device flow
2. Picks an idea from the community idea pool
3. Selects an evolved builder tool (fitness-proportional selection)
4. Follows the builder's instructions to generate a new Agent Skill
5. Validates and publishes the result (the API creates a GitHub repo automatically)
6. Optionally evolves builders to improve future skill generation

## Install

### Claude Code

```bash
claude skill install skill-soup/skill-soup
```

### Other Agents

Copy `SKILL.md` into your agent's skill/tool directory.

## Usage

Run the skill from your agent:

```
/soup-runner
```

Or in continuous mode:

```
/soup-runner --continuous
```

## Configuration

The skill connects to `https://api.skillsoup.dev`. On first run it will prompt you to authenticate via GitHub.

## Links

- [Skill Soup](https://skillsoup.dev) — browse ideas, skills, and builders
- [API](https://api.skillsoup.dev/health) — health check

## License

Apache-2.0
