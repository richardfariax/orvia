#!/usr/bin/env bash
# Fonte de verdade da versão do produto: project.yml (MARKETING_VERSION + CURRENT_PROJECT_VERSION).
# O app lê esses valores via Info.plist → Bundle. Tags Git e releases devem espelhar MARKETING_VERSION.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

PROJECT_YML="project.yml"
PBXPROJ="Orvia.xcodeproj/project.pbxproj"

usage() {
  cat <<'EOF'
Uso: Scripts/version.sh <comando>

Comandos:
  status              Mostra versão do projeto, pbxproj e última tag Git
  check               Falha se project.yml e pbxproj estiverem dessincronizados
  read                Imprime só MARKETING_VERSION (ex.: 2.0.0)
  read-build          Imprime só CURRENT_PROJECT_VERSION (ex.: 6)
  bump <X.Y.Z> [N]    Atualiza project.yml + pbxproj (build = N ou atual+1)
  verify-app <app>    Confere CFBundle* do .app com project.yml
  compare-tag <tag>   Confere se a tag (ex.: 2.0.0 ou v2.0.0) == MARKETING_VERSION

EOF
}

read_yml_marketing() {
  awk '/^[[:space:]]*MARKETING_VERSION:/ {print $2; exit}' "${PROJECT_YML}"
}

read_yml_build() {
  awk '/^[[:space:]]*CURRENT_PROJECT_VERSION:/ {print $2; exit}' "${PROJECT_YML}"
}

read_pbx_marketing() {
  # Pega o primeiro MARKETING_VERSION do projeto (Debug/Release compartilham o valor).
  awk -F' = ' '/MARKETING_VERSION = / { gsub(/;/, "", $2); print $2; exit }' "${PBXPROJ}"
}

read_pbx_build() {
  awk -F' = ' '/CURRENT_PROJECT_VERSION = / { gsub(/;/, "", $2); print $2; exit }' "${PBXPROJ}"
}

normalize_tag() {
  local tag="$1"
  tag="${tag#v}"
  echo "${tag}"
}

semver_gt() {
  # Retorna 0 se $1 > $2 (sort -V).
  local a="$1" b="$2"
  [[ "${a}" != "${b}" ]] && [[ "$(printf '%s\n%s\n' "${a}" "${b}" | sort -V | tail -n 1)" == "${a}" ]]
}

cmd_status() {
  local yml_v yml_b pbx_v pbx_b latest_tag tag_v
  yml_v="$(read_yml_marketing)"
  yml_b="$(read_yml_build)"
  pbx_v="$(read_pbx_marketing)"
  pbx_b="$(read_pbx_build)"
  latest_tag="$(git tag --list 2>/dev/null | sed 's/^v//' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -n 1 || true)"
  tag_v=""
  if [[ -n "${latest_tag}" ]]; then
    tag_v="$(normalize_tag "${latest_tag}")"
  fi

  echo "project.yml : ${yml_v} (build ${yml_b})"
  echo "pbxproj     : ${pbx_v} (build ${pbx_b})"
  if [[ -n "${latest_tag}" ]]; then
    echo "git tag     : ${latest_tag} → ${tag_v}"
  else
    echo "git tag     : (nenhuma)"
  fi

  if [[ "${yml_v}" == "${pbx_v}" && "${yml_b}" == "${pbx_b}" ]]; then
    echo "sync files  : OK"
  else
    echo "sync files  : DRIFT (rode: Scripts/version.sh bump ${yml_v} ${yml_b})"
  fi

  if [[ -z "${tag_v}" ]]; then
    echo "sync git    : sem tags"
  elif [[ "${yml_v}" == "${tag_v}" ]]; then
    echo "sync git    : OK (tag == produto)"
  elif semver_gt "${yml_v}" "${tag_v}"; then
    echo "sync git    : pendente release (produto ${yml_v} > tag ${tag_v})"
  else
    echo "sync git    : ERRO (tag ${tag_v} > produto ${yml_v})"
  fi
}

cmd_check() {
  local yml_v yml_b pbx_v pbx_b
  yml_v="$(read_yml_marketing)"
  yml_b="$(read_yml_build)"
  pbx_v="$(read_pbx_marketing)"
  pbx_b="$(read_pbx_build)"

  if [[ -z "${yml_v}" || -z "${yml_b}" || -z "${pbx_v}" || -z "${pbx_b}" ]]; then
    echo "Erro: não foi possível ler versões de ${PROJECT_YML} / ${PBXPROJ}." >&2
    exit 1
  fi

  if [[ ! "${yml_v}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Erro: MARKETING_VERSION inválida '${yml_v}'." >&2
    exit 1
  fi

  if [[ "${yml_v}" != "${pbx_v}" || "${yml_b}" != "${pbx_b}" ]]; then
    echo "Erro: versões dessincronizadas." >&2
    echo "  project.yml → ${yml_v} (${yml_b})" >&2
    echo "  pbxproj     → ${pbx_v} (${pbx_b})" >&2
    exit 1
  fi

  echo "OK ${yml_v} (build ${yml_b})"
}

cmd_bump() {
  local new_version="${1:-}"
  local new_build="${2:-}"

  if [[ -z "${new_version}" ]]; then
    echo "Uso: Scripts/version.sh bump <X.Y.Z> [build]" >&2
    exit 1
  fi

  if [[ ! "${new_version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Erro: versão inválida '${new_version}'. Use X.Y.Z." >&2
    exit 1
  fi

  if [[ -z "${new_build}" ]]; then
    local current_build
    current_build="$(read_yml_build)"
    new_build=$((current_build + 1))
  fi

  if [[ ! "${new_build}" =~ ^[0-9]+$ ]]; then
    echo "Erro: build inválido '${new_build}'." >&2
    exit 1
  fi

  chmod +x Scripts/bump_versions.sh
  ./Scripts/bump_versions.sh "${new_version}" "${new_build}"
  cmd_check
}

cmd_verify_app() {
  local app_path="${1:-}"
  if [[ -z "${app_path}" || ! -d "${app_path}" ]]; then
    echo "Uso: Scripts/version.sh verify-app <Orvia.app>" >&2
    exit 1
  fi

  local plist="${app_path}/Contents/Info.plist"
  if [[ ! -f "${plist}" ]]; then
    echo "Erro: Info.plist não encontrado em ${app_path}" >&2
    exit 1
  fi

  local expected_v expected_b app_v app_b app_id app_name minimum_system
  expected_v="$(read_yml_marketing)"
  expected_b="$(read_yml_build)"
  app_v="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${plist}")"
  app_b="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${plist}")"
  app_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${plist}")"
  app_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "${plist}")"
  minimum_system="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "${plist}")"

  if [[ "${app_v}" != "${expected_v}" || "${app_b}" != "${expected_b}" ]]; then
    echo "Erro: binário não corresponde ao projeto." >&2
    echo "  esperado → ${expected_v} (${expected_b})" >&2
    echo "  app      → ${app_v} (${app_b})" >&2
    exit 1
  fi

  if [[ "${app_id}" != "com.richadfarias.orvia" || "${app_name}" != "Orvia" || "${minimum_system}" != "27.0" ]]; then
    echo "Erro: identidade ou versão mínima inválida no bundle: ${app_id}, ${app_name}, macOS ${minimum_system}" >&2
    exit 1
  fi

  echo "OK app ${app_v} (build ${app_b})"
}

cmd_compare_tag() {
  local raw_tag="${1:-}"
  if [[ -z "${raw_tag}" ]]; then
    echo "Uso: Scripts/version.sh compare-tag <tag>" >&2
    exit 1
  fi

  local tag_v expected_v
  tag_v="$(normalize_tag "${raw_tag}")"
  expected_v="$(read_yml_marketing)"

  if [[ "${tag_v}" != "${expected_v}" ]]; then
    echo "Erro: tag '${raw_tag}' (${tag_v}) ≠ MARKETING_VERSION ${expected_v}." >&2
    exit 1
  fi

  echo "OK tag ${tag_v} == produto"
}

main() {
  local cmd="${1:-}"
  shift || true

  case "${cmd}" in
    status) cmd_status ;;
    check) cmd_check ;;
    read) read_yml_marketing ;;
    read-build) read_yml_build ;;
    bump) cmd_bump "$@" ;;
    verify-app) cmd_verify_app "$@" ;;
    compare-tag) cmd_compare_tag "$@" ;;
    -h|--help|help|"") usage; [[ -n "${cmd}" ]] || exit 1 ;;
    *) echo "Comando desconhecido: ${cmd}" >&2; usage; exit 1 ;;
  esac
}

main "$@"
