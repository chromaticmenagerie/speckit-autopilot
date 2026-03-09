#!/usr/bin/env bash
# autopilot-design.sh — Extract structural data from Pencil .pen files for LLM prompts

# Extract screen inventory, design tokens, and component trees from a .pen file.
# Returns a compact text summary; returns empty string on any error.
extract_pen_structure() {
  local pen_file="${1:-}"

  # Guard: file must exist and be readable
  if [[ -z "$pen_file" ]] || [[ ! -r "$pen_file" ]]; then
    return 0
  fi

  # Guard: jq must be available
  if ! command -v jq &>/dev/null; then
    return 0
  fi

  local output
  output=$(jq -r '
    # ── Screen inventory ──
    def viewport:
      if .width == null or (.width | type) == "string" then "Auto"
      elif .width >= 1024 then "Desktop"
      elif .width >= 768 then "Tablet"
      else "Mobile"
      end;

    def dims:
      (if .width then (.width | tostring) else "?" end)
      + " × "
      + (if .height then (.height | tostring) else "?" end);

    def screen_rows:
      [.children[] |
        "| " + (.name // "unnamed") + " | " + viewport + " | " + dims + " |"
      ] | join("\n");

    # ── Design tokens ──
    def token_rows:
      if .variables and (.variables | length > 0) then
        [.variables | to_entries[] |
          "| " + .key + " | " + (.value.type // "?") + " | " + (.value.value // "?" | tostring) + " |"
        ] | join("\n")
      else
        "(none)"
      end;

    # ── Screen trees (recursive) ──
    def indent(d): d * "  ";

    def extract(d):
      indent(d) + (.type // "?") + " \"" + (.name // "unnamed") + "\""
      + (if .width then " w=" + (.width | tostring) else "" end)
      + (if .height then " h=" + (.height | tostring) else "" end)
      + (if .layout then " layout=" + .layout else "" end)
      + (if .gap then " gap=" + (.gap | tostring) else "" end)
      + (if .padding then " pad=" + (.padding | tostring) else "" end)
      + (if .fill then " fill=" + (.fill | tostring) else "" end)
      + (if .cornerRadius then " r=" + (.cornerRadius | tostring) else "" end)
      + (if .fontSize then " fs=" + (.fontSize | tostring) else "" end)
      + (if .fontWeight then " fw=" + (.fontWeight | tostring) else "" end)
      + (if .iconFontName then " icon=" + .iconFontName else "" end)
      + (if .alignItems then " align=" + .alignItems else "" end)
      + (if .justifyContent then " justify=" + .justifyContent else "" end)
      + (if .stroke then " stroke=" + (.stroke | tostring) else "" end)
      + (if .reusable then " [REUSABLE]" else "" end)
      + (if .content then " content=\"" + (.content | tostring | .[0:50]) + "\"" else "" end),
      if .children and d < 8 then (.children[] | extract(d + 1)) else empty end;

    def screen_trees:
      [.children[] |
        "── " + (.name // "unnamed") + " ──",
        extract(0)
      ] | join("\n");

    # ── Assemble output ──
    "=== SCREENS ===\n"
    + "| Name | Viewport | Dimensions |\n"
    + "|------|----------|------------|\n"
    + screen_rows + "\n\n"
    + "=== DESIGN TOKENS ===\n"
    + "| Token | Type | Value |\n"
    + "|-------|------|-------|\n"
    + token_rows + "\n\n"
    + "=== SCREEN TREES ===\n"
    + screen_trees
  ' "$pen_file" 2>/dev/null) || true

  # Only emit if jq produced output
  if [[ -n "$output" ]]; then
    echo "$output"
  fi
}
