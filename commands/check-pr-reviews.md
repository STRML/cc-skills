# Check PR

Find and address comments on the current repo's latest PR.

## Steps

1. **Find the PR for the current branch:**
   ```bash
   gh pr view --json number,title,url
   ```
   This finds the PR associated with the current git branch. If no PR exists for the current branch, tell the user and stop.

2. **Fetch comments and reviews:**
   ```bash
   # Get the repo owner/name
   gh repo view --json nameWithOwner --jq '.nameWithOwner'

   # PR review comments (inline on code)
   gh api repos/{owner}/{repo}/pulls/{number}/comments --paginate

   # PR reviews (top-level review bodies)
   gh api repos/{owner}/{repo}/pulls/{number}/reviews --paginate

   # Issue comments (conversation thread)
   gh api repos/{owner}/{repo}/issues/{number}/comments --paginate
   ```

3. **Process each comment:**

   For each comment, check the author:

   **CodeRabbit comments** (`author.login` contains `coderabbitai`):
   - CodeRabbit comments contain structured review feedback
   - Look for inline code suggestions and actionable items
   - Extract the exact suggestion/finding verbatim
   - For each actionable item: verify against the current code, then fix if the finding is valid
   - Skip nitpicks and suggestions that don't apply

   **Claude bot comments** (`author.login` contains `claude`):
   - These are from our own code review — skip unless they contain unresolved items

   **Human comments:**
   - Summarize what the reviewer is asking for
   - Address each point — fix the code if it's a valid request, or explain why not

4. **For each fix:**
   - Read the referenced file to verify the issue exists in current code
   - Make the fix
   - Note what was changed

5. **After all comments are addressed:**
   - Commit with a descriptive message referencing the PR
   - Push the changes
   - Summarize what was addressed and what was skipped (with reasons)

## Important

- Always verify findings against current code before fixing — comments may reference outdated code
- Don't fix things that were already addressed in subsequent commits
- For CodeRabbit, treat inline suggestions as the authoritative request — use the verbatim suggestion text as the prompt for what to change
- Group related fixes into a single commit when possible
