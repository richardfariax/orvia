#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Uso: $0 <marketing_version> <build_number>" >&2
  echo "Prefira: Scripts/version.sh bump <X.Y.Z> [build]" >&2
  exit 1
fi

new_version="$1"
new_build="$2"

if [[ ! "${new_version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Erro: versão inválida '${new_version}'. Use o formato X.Y.Z." >&2
  exit 1
fi

if [[ ! "${new_build}" =~ ^[0-9]+$ ]]; then
  echo "Erro: build number inválido '${new_build}'." >&2
  exit 1
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
project_file="${ROOT}/project.yml"
pbxproj_file="${ROOT}/Orvia.xcodeproj/project.pbxproj"

if [[ ! -f "${project_file}" || ! -f "${pbxproj_file}" ]]; then
  echo "Erro: arquivos de versão não encontrados." >&2
  exit 1
fi

# Usar ENV evita o bug clássico do Perl ($12.0.1 = grupo 12 + ".0.1").
NEW_VERSION="${new_version}" NEW_BUILD="${new_build}" perl -i -pe \
  's/(MARKETING_VERSION:\s*)\d+\.\d+\.\d+/$1$ENV{NEW_VERSION}/g; s/(CURRENT_PROJECT_VERSION:\s*)\d+/$1$ENV{NEW_BUILD}/g' \
  "${project_file}"

NEW_VERSION="${new_version}" NEW_BUILD="${new_build}" perl -i -pe \
  's/(MARKETING_VERSION = )[^;]+;/$1$ENV{NEW_VERSION};/g; s/(CURRENT_PROJECT_VERSION = )\d+;/$1$ENV{NEW_BUILD};/g' \
  "${pbxproj_file}"

echo "Versão atualizada para ${new_version} (build ${new_build})."
