# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands
- Build: N/A (Add build command when available)
- Lint: N/A (Add lint command when available)
- Test: N/A (Add test command when available)
- Run single test: N/A (Add single test command when available)

## BGP Infrastructure Standard Procedures

### Instance Creation Requirements
**MANDATORY for all BGP node deployments:**
1. **IPv6 MUST be enabled**: Always set `"enable_ipv6": true` in Vultr API calls
2. **Dual SSH keys MUST be included**: Include both legacy and current SSH keys:
   - `"9bd72db9-f745-4b0f-b9b2-55c967f3fae1"` (nt@infinitum-nihil.com - legacy)
   - `"f190effd-73b3-4ac1-8b6a-0d847703e45f"` (normtodd@NTubuntu - current)
3. **Plan sizing**: Use minimum 2c2g (2 CPU, 2GB RAM) for full table BGP + Docker
4. **Firewall group**: Always attach BGP firewall group `"c07c67b8-7cd2-405a-a559-65578a1edbad"`

### Why These Requirements
- **IPv6**: Required for dual-stack BGP announcements and global connectivity
- **Dual SSH**: Ensures access regardless of which key is currently in use locally
- **Instance sizing**: 1c1g insufficient for full BGP table plus containerized services
- **Firewall**: Consistent security posture across all BGP infrastructure

## Code Style Guidelines
- **Formatting**: Follow consistent indentation (2 spaces recommended)
- **Naming**: Use descriptive names in camelCase for variables/functions, PascalCase for classes
- **Imports**: Group imports by external libraries, then internal modules
- **Types**: Use strong typing where available
- **Error Handling**: Use try/catch blocks for error-prone operations
- **Comments**: Document complex logic, avoid obvious comments
- **Functions**: Keep functions small and focused on a single responsibility

## Repository Structure
Follow existing patterns when adding new files or directories.