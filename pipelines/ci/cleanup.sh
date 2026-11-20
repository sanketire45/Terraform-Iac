#!/usr/bin/env bash
# ════════════════════════════════════════════════════════════════════════
#  cleanup.sh — runs in every Jenkinsfile's post { cleanup { … } } (always, success or failure)
#  Removes everything that must not outlive the build: the temporary AWS session, the git token config, kubeconfigs, and the saved plans
#  (binary + JSON hold resolved/sensitive values). The redacted plan.txt files were already archived by the Jenkinsfile.
# ════════════════════════════════════════════════════════════════════════
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

rm -f "$STATE_DIR"/aws-*.env "$STATE_DIR/gitconfig" "$STATE_DIR/approval.tmp"
find "$STATE_DIR" -maxdepth 1 \( -name 'kubeconfig*' -o -name 'helm-values-*' -o -name 'boot-state' \) -exec rm -rf {} + 2>/dev/null || true
find "$WORK" \( -name 'tfplan' -o -name 'tfplan.json' -o -name 'terraform.tfstate*' -o -name '.terraform' \) -prune -exec rm -rf {} + 2>/dev/null || true
log "build credentials and saved plans removed"

# ════════════════════════════════════════════════════════════════════════
# EXPLAINED
#   post { cleanup {} }     Jenkins runs this block after success/failure/abort alike, so a failed build cannot leave credentials behind.
#   what is removed         aws-<scope>.env (the assumed-role sessions), gitconfig (it embeds the modules-repo token), kubeconfigs, helm values files,
#                           and tfplan / tfplan.json / .terraform / local bootstrap state under .work/.
#   what is kept            plan.txt, plan.log and the summaries — archived by the Jenkinsfile before this runs, and free of sensitive values.
#   `|| true`               cleanup must never fail the build; a missing file is fine.
# ════════════════════════════════════════════════════════════════════════
