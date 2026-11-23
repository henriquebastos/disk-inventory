#!/bin/bash
# Sets up the GitHub repository for the release workflow (docs/release.md). Each step can run
# again; it changes only what is missing or different. Needs gh, logged in as the owner.
# Usage: scripts/setup-github.sh STEP OWNER/NAME [ARGUMENTS]
#   repo OWNER/NAME              create the public repository and add it as the origin remote;
#                                it does not push
#   protect OWNER/NAME [USER]    create the release environment for main and v* tags only,
#                                with USER as an optional required reviewer, and a ruleset
#                                that lets only administrators create, move or delete v* tags
#   csr OWNER/NAME KEYDIR        write a new private key and a certificate signing request to
#                                KEYDIR, a folder outside Git; upload the request to Apple
#   secrets OWNER/NAME KEYDIR CER
#                                check the API key with the notary service, then store the
#                                five release secrets in the release environment; CER is the
#                                Developer ID Application certificate that Apple made from the
#                                request, and NOTARY_KEY_PATH, NOTARY_KEY_ID and
#                                NOTARY_ISSUER_ID name the App Store Connect API key
#   status OWNER/NAME            show the environment, the ruleset and the secret names
# No step prints a secret value.
set -euo pipefail
usage() { awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0" >&2; exit 2; }
[[ $# -ge 2 && $2 == */* ]] || usage
step=$1 repo=$2
shift 2
umask 077

case $step in
repo)
  [[ $# -eq 0 ]] || usage
  if gh repo view "$repo" --json name > /dev/null 2>&1; then
    echo "repository $repo exists"
  else
    gh repo create "$repo" --public \
      --description "Find the large files and folders on a Mac disk and free the space"
  fi
  url="https://github.com/$repo.git"
  current=$(git remote get-url origin 2>/dev/null || true)
  if [[ -z $current ]]; then
    git remote add origin "$url"
  elif [[ $current != "$url" ]]; then
    echo "origin is $current, expected $url" >&2; exit 1
  fi
  echo "origin: $url"
  ;;
protect)
  [[ $# -le 1 ]] || usage
  reviewers='[]'
  if [[ $# -eq 1 ]]; then
    reviewers="[{\"type\":\"User\",\"id\":$(gh api "users/$1" --jq .id)}]"
  fi
  gh api -X PUT "repos/$repo/environments/release" --input - > /dev/null <<EOF
{"deployment_branch_policy": {"protected_branches": false, "custom_branch_policies": true},
 "reviewers": $reviewers}
EOF
  policies="repos/$repo/environments/release/deployment-branch-policies"
  present=$(gh api "$policies" --jq '.branch_policies[] | "\(.type) \(.name)"')
  for policy in "branch main" "tag v*"; do
    grep -qxF "$policy" <<< "$present" ||
      gh api -X POST "$policies" -f type="${policy% *}" -f name="${policy#* }" > /dev/null
  done
  ruleset=$(gh api "repos/$repo/rulesets" --jq '.[] | select(.name == "release tags") | .id')
  method=POST path="repos/$repo/rulesets"
  [[ -z $ruleset ]] || method=PUT path="repos/$repo/rulesets/$ruleset"
  # Actor 5 is the repository administrator role.
  gh api -X "$method" "$path" --input - > /dev/null <<'EOF'
{"name": "release tags", "target": "tag", "enforcement": "active",
 "conditions": {"ref_name": {"include": ["refs/tags/v*"], "exclude": []}},
 "rules": [{"type": "creation"}, {"type": "update"}, {"type": "deletion"}],
 "bypass_actors": [{"actor_id": 5, "actor_type": "RepositoryRole", "bypass_mode": "always"}]}
EOF
  echo "release environment and the release tags ruleset are set"
  ;;
csr)
  [[ $# -eq 1 ]] || usage
  mkdir -p "$1"
  key="$1/developer-id.key" request="$1/developer-id.certSigningRequest"
  [[ ! -e $key ]] || { echo "$key exists; use it or remove it" >&2; exit 1; }
  openssl genrsa -out "$key" 2048 2> /dev/null
  openssl req -new -key "$key" -subj "/CN=Disk Inventory release" -out "$request"
  echo "request: $request"
  echo "Upload it at developer.apple.com, Certificates, +, Developer ID Application."
  ;;
secrets)
  [[ $# -eq 2 ]] || usage
  key="$1/developer-id.key" cer=$2 work="$1/work"
  : "${NOTARY_KEY_PATH:?}" "${NOTARY_KEY_ID:?}" "${NOTARY_ISSUER_ID:?}"
  rm -rf "$work"
  mkdir -p "$work"
  trap 'rm -rf "$work"' EXIT
  openssl x509 -inform DER -in "$cer" -out "$work/cert.pem" 2> /dev/null ||
    openssl x509 -in "$cer" -out "$work/cert.pem"
  subject=$(openssl x509 -in "$work/cert.pem" -noout -subject -nameopt multiline |
    sed -n 's/^ *commonName *= //p')
  [[ $subject == "Developer ID Application: "* ]] ||
    { echo "certificate is '$subject', expected a Developer ID Application" >&2; exit 1; }
  # The runner may not have the Apple intermediate certificate, so the .p12 file carries it.
  # Apple certificates name no issuer URL; the intermediate comes from the local keychains.
  name=$(openssl x509 -in "$work/cert.pem" -noout -issuer -nameopt multiline |
    sed -n 's/^ *commonName *= //p')
  key_id() { openssl x509 -in "$1" -noout -ext "$2" | tail -1 | tr -d ' ' | sed 's/^keyid://'; }
  wanted=$(key_id "$work/cert.pem" authorityKeyIdentifier)
  security find-certificate -a -p -c "$name" ~/Library/Keychains/login.keychain-db \
    /Library/Keychains/System.keychain /System/Library/Keychains/SystemRootCertificates.keychain |
    awk -v dir="$work" '/BEGIN/ { n++ } { print > (dir "/ca" n ".pem") }' || true
  for ca in "$work"/ca*.pem; do
    if [[ -e $ca && $(key_id "$ca" subjectKeyIdentifier) == "$wanted" ]]; then
      cp "$ca" "$work/issuer.pem"
    fi
  done
  [[ -s $work/issuer.pem ]] || { echo "no keychain has the issuer '$name'" >&2; exit 1; }
  [[ $(openssl x509 -in "$work/cert.pem" -noout -pubkey) == $(openssl pkey -in "$key" -pubout) ]] ||
    { echo "certificate does not belong to $key" >&2; exit 1; }
  xcrun notarytool history --key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" \
    --issuer "$NOTARY_ISSUER_ID" > /dev/null
  password=$(openssl rand -hex 24)
  # The security tool on macOS reads SHA-1 and 3DES protected files.
  openssl pkcs12 -export -inkey "$key" -in "$work/cert.pem" -certfile "$work/issuer.pem" \
    -name "$subject" -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 \
    -passout fd:3 -out "$work/developer-id.p12" 3<<< "$password"
  set_secret() { gh secret set "$1" --env release --repo "$repo" > /dev/null; }
  base64 -i "$work/developer-id.p12" | set_secret DEVELOPER_ID_P12_BASE64
  printf '%s' "$password" | set_secret DEVELOPER_ID_P12_PASSWORD
  set_secret NOTARY_KEY_P8 < "$NOTARY_KEY_PATH"
  printf '%s' "$NOTARY_KEY_ID" | set_secret NOTARY_KEY_ID
  printf '%s' "$NOTARY_ISSUER_ID" | set_secret NOTARY_ISSUER_ID
  echo "release secrets are set for $subject"
  ;;
status)
  [[ $# -eq 0 ]] || usage
  gh api "repos/$repo/environments/release" \
    --jq '"reviewers: \([.protection_rules[]? | select(.type == "required_reviewers") | .reviewers[].reviewer.login] | join(", "))"'
  gh api "repos/$repo/environments/release/deployment-branch-policies" \
    --jq '.branch_policies[] | "deploys from \(.type) \(.name)"'
  gh api "repos/$repo/rulesets" --jq '.[] | "ruleset: \(.name) (\(.enforcement))"'
  gh secret list --env release --repo "$repo"
  ;;
*) usage ;;
esac
