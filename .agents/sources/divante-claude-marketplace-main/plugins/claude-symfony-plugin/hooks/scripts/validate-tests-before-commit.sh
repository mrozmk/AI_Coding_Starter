#!/bin/bash
set -euo pipefail

# Read hook input from stdin
input=$(cat)

# Extract the command being executed
command=$(echo "$input" | jq -r '.tool_input.command // ""')

# Only intercept git commit commands
if [[ ! "$command" =~ ^git[[:space:]]+commit ]]; then
    # Not a git commit, allow it
    exit 0
fi

# Check if we're in a Symfony project (has bin/phpunit or vendor/bin/phpunit)
project_dir="${CLAUDE_PROJECT_DIR:-$(pwd)}"

phpunit_bin=""
if [ -f "$project_dir/bin/phpunit" ]; then
    phpunit_bin="$project_dir/bin/phpunit"
elif [ -f "$project_dir/vendor/bin/phpunit" ]; then
    phpunit_bin="$project_dir/vendor/bin/phpunit"
fi

# If no PHPUnit found, allow the commit (might not be a PHP project)
if [ -z "$phpunit_bin" ]; then
    exit 0
fi

# Run PHPUnit tests
echo "Running PHPUnit tests before commit..." >&2

cd "$project_dir"

if $phpunit_bin --colors=never 2>&1; then
    # Tests passed, allow the commit
    echo '{"hookSpecificOutput": {"permissionDecision": "allow"}, "systemMessage": "All PHPUnit tests passed. Proceeding with commit."}'
    exit 0
else
    # Tests failed, block the commit
    echo '{"hookSpecificOutput": {"permissionDecision": "deny"}, "systemMessage": "PHPUnit tests failed. Fix the failing tests before committing. Run php bin/phpunit to see the failures."}' >&2
    exit 2
fi
