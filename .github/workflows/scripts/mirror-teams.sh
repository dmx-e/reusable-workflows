#!/bin/bash

TARGET_ORG="${1:-}"
TARGET_URL="${2:-https://github.com}"
EXPORT_FILE="teams-export.json"
MIRROR_MODE="${MIRROR_MODE:-auto}"  # Options: auto, idp-only, members-only, teams-only

if [ -z "$TARGET_ORG" ]; then
    echo "Usage: ./mirror-teams.sh <target-org> [target-url]"
    echo ""
    echo "Environment variables:"
    echo "  MIRROR_MODE: What to mirror (default: auto)"
    echo "    - auto: Use mode from export file"
    echo "    - idp-only: Mirror teams and show IdP configuration needed"
    echo "    - members-only: Mirror teams and members only"
    echo "    - teams-only: Mirror teams structure only"
    exit 1
fi

if [ ! -f "$EXPORT_FILE" ]; then
    echo "Error: $EXPORT_FILE not found. Run export-teams.sh first."
    exit 1
fi

# Extract hostname from URL
TARGET_HOST=$(echo "$TARGET_URL" | sed -e 's|^https://||' -e 's|^http://||' -e 's|/.*||')

# Determine effective mirror mode
if [ "$MIRROR_MODE" = "auto" ]; then
    EFFECTIVE_MODE=$(jq -r '.export_mode // "all"' "$EXPORT_FILE")
    echo "Using export mode from file: $EFFECTIVE_MODE"
else
    EFFECTIVE_MODE="$MIRROR_MODE"
    echo "Using override mode: $EFFECTIVE_MODE"
fi

echo "Mirroring teams to organization: $TARGET_ORG on $TARGET_HOST"
echo "Mirror mode: $EFFECTIVE_MODE"
echo "---"

# First pass: Create parent teams (teams without parents)
echo "Creating parent teams..."
while IFS= read -r team; do
    slug=$(echo "$team" | jq -r '.slug')
    name=$(echo "$team" | jq -r '.name')
    description=$(echo "$team" | jq -r '.description // ""')
    privacy=$(echo "$team" | jq -r '.privacy // "closed"')
    parent=$(echo "$team" | jq -r '.parent // ""')
    
    if [ -z "$parent" ]; then
        echo "  Creating team: $name"
        
        if gh api --hostname "$TARGET_HOST" "orgs/$TARGET_ORG/teams" --method POST \
            -f name="$name" \
            -f description="$description" \
            -f privacy="$privacy" 2>/dev/null; then
            echo "  ✓ Created team: $name"
        else
            echo "  ⚠ Team $name already exists or creation failed, updating..."
            gh api --hostname "$TARGET_HOST" "orgs/$TARGET_ORG/teams/$slug" --method PATCH \
                -f name="$name" \
                -f description="$description" \
                -f privacy="$privacy" 2>/dev/null || echo "  ⚠ Failed to update $name"
        fi
    fi
done < <(jq -c '.teams[]' "$EXPORT_FILE")

# Second pass: Create child teams (teams with parents)
echo "Creating child teams..."
while IFS= read -r team; do
    slug=$(echo "$team" | jq -r '.slug')
    name=$(echo "$team" | jq -r '.name')
    description=$(echo "$team" | jq -r '.description // ""')
    privacy=$(echo "$team" | jq -r '.privacy // "closed"')
    parent=$(echo "$team" | jq -r '.parent // ""')
    
    if [ -n "$parent" ]; then
        echo "  Creating child team: $name (parent: $parent)"
        
        parent_id=$(gh api --hostname "$TARGET_HOST" "orgs/$TARGET_ORG/teams/$parent" --jq '.id' 2>/dev/null)
        if [ -n "$parent_id" ]; then
            if gh api --hostname "$TARGET_HOST" "orgs/$TARGET_ORG/teams" --method POST \
                -f name="$name" \
                -f description="$description" \
                -f privacy="$privacy" \
                -f parent_team_id="$parent_id" 2>/dev/null; then
                echo "  ✓ Created child team: $name"
            else
                echo "  ⚠ Team $name already exists or creation failed"
            fi
        else
            echo "  ⚠ Parent team '$parent' not found, skipping $name"
        fi
    fi
done < <(jq -c '.teams[]' "$EXPORT_FILE")

# Third pass: Configure IdP group mappings (if mode allows)
if [ "$EFFECTIVE_MODE" = "all" ] || [ "$EFFECTIVE_MODE" = "idp-only" ]; then
    idp_count=$(jq '.idp_groups | length' "$EXPORT_FILE")
    if [ "$idp_count" -gt 0 ]; then
        echo ""
        echo "=== IdP Group Mappings ==="
        echo "The following teams require IdP group configuration:"
        echo ""
        while IFS= read -r mapping; do
            team=$(echo "$mapping" | jq -r '.team')
            groups=$(echo "$mapping" | jq -c '.groups')
            
            echo "Team: $team"
            echo "$groups" | jq -r '.[] | "  - \(.group_name) (\(.group_id))"'
            echo ""
        done < <(jq -c '.idp_groups[]' "$EXPORT_FILE")
        
        echo "⚠ MANUAL ACTION REQUIRED:"
        echo "  1. Configure SAML/SCIM in target organization settings"
        echo "  2. Map the above IdP groups to their respective teams"
        echo "  3. Trigger an IdP sync to populate memberships"
        echo ""
    fi
fi

# Fourth pass: Add team members (if mode allows)
if [ "$EFFECTIVE_MODE" = "all" ] || [ "$EFFECTIVE_MODE" = "members-only" ]; then
    membership_count=$(jq '.memberships | length' "$EXPORT_FILE")
    if [ "$membership_count" -gt 0 ]; then
        echo "Adding team members..."
        while IFS= read -r membership; do
            team=$(echo "$membership" | jq -r '.team')
            username=$(echo "$membership" | jq -r '.username')
            role=$(echo "$membership" | jq -r '.role // "member"')
            
            echo "  Adding $username to $team as $role"
            
            if gh api --hostname "$TARGET_HOST" "orgs/$TARGET_ORG/teams/$team/memberships/$username" --method PUT \
                -f role="$role" 2>/dev/null; then
                echo "  ✓ Added $username to $team"
            else
                echo "  ⚠ Failed to add $username to $team (user may not exist in target org)"
            fi
        done < <(jq -c '.memberships[]' "$EXPORT_FILE")
    else
        echo "No manual memberships to add"
    fi
fi

echo "---"
echo ""
echo "=== Mirror Summary ==="
echo "Mode: $EFFECTIVE_MODE"
echo "Teams created/updated: $(jq '.teams | length' "$EXPORT_FILE")"

if [ "$EFFECTIVE_MODE" = "all" ] || [ "$EFFECTIVE_MODE" = "members-only" ]; then
    echo "Members added: $(jq '.memberships | length' "$EXPORT_FILE")"
fi

if [ "$EFFECTIVE_MODE" = "all" ] || [ "$EFFECTIVE_MODE" = "idp-only" ]; then
    idp_count=$(jq '.idp_groups | length' "$EXPORT_FILE")
    echo "IdP mappings requiring configuration: $idp_count"
fi

echo ""
echo "Team mirroring complete!"
