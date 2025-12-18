#!/bin/bash

SOURCE_ORG="${1:-}"
SOURCE_URL="${2:-https://github.com}"
EXPORT_MODE="${EXPORT_MODE:-all}"  # Options: all, idp-only, members-only, teams-only

if [ -z "$SOURCE_ORG" ]; then
    echo "Usage: ./export-teams.sh <source-org> [source-url]"
    echo ""
    echo "Environment variables:"
    echo "  EXPORT_MODE: What to export (default: all)"
    echo "    - all: Export teams, members, and IdP groups"
    echo "    - idp-only: Export teams and IdP groups only"
    echo "    - members-only: Export teams and members only"
    echo "    - teams-only: Export teams structure only (no members or IdP groups)"
    exit 1
fi

# Extract hostname from URL
SOURCE_HOST=$(echo "$SOURCE_URL" | sed -e 's|^https://||' -e 's|^http://||' -e 's|/.*||')

echo "Exporting teams from organization: $SOURCE_ORG on $SOURCE_HOST"
echo "Export mode: $EXPORT_MODE"

# Initialize JSON structure
echo '{"teams": [], "memberships": [], "idp_groups": [], "export_mode": "'$EXPORT_MODE'"}' > teams-export.json

# Export all teams (including parent teams)
echo "Fetching teams..."
teams_data=$(gh api --hostname "$SOURCE_HOST" "orgs/$SOURCE_ORG/teams" --paginate --jq '[.[] | {
    slug: .slug,
    name: .name,
    description: .description,
    privacy: .privacy,
    permission: .permission,
    parent: .parent.slug // null,
    ldap_dn: .ldap_dn // null
}]')

# Export based on mode
memberships_data="[]"
idp_groups_data="[]"

if [ "$EXPORT_MODE" = "teams-only" ]; then
    echo "Skipping member and IdP group export (teams-only mode)"
else
    echo "Fetching team details..."
    for team_slug in $(echo "$teams_data" | jq -r '.[].slug'); do
        echo "  Processing team: $team_slug"
        
        # Check if team is synced with IdP
        team_sync=$(gh api --hostname "$SOURCE_HOST" "orgs/$SOURCE_ORG/teams/$team_slug/team-sync/group-mappings" 2>/dev/null || echo "[]")
        has_idp=$(echo "$team_sync" | jq 'if . == [] or . == null then false else true end')
        
        # Export IdP groups if mode allows
        if [ "$has_idp" = "true" ] && { [ "$EXPORT_MODE" = "all" ] || [ "$EXPORT_MODE" = "idp-only" ]; }; then
            echo "  → Exporting IdP groups for $team_slug"
            idp_group_data=$(echo "$team_sync" | jq --arg team "$team_slug" '{
                team: $team,
                groups: .groups
            }')
            idp_groups_data=$(echo "$idp_groups_data [$idp_group_data]" | jq -s 'add')
        fi
        
        # Export members based on mode and IdP status
        should_export_members=false
        
        if [ "$EXPORT_MODE" = "all" ]; then
            # In 'all' mode, export members for non-IdP teams
            if [ "$has_idp" = "false" ]; then
                should_export_members=true
            fi
        elif [ "$EXPORT_MODE" = "members-only" ]; then
            # In 'members-only' mode, export all members regardless of IdP
            should_export_members=true
        fi
        
        if [ "$should_export_members" = "true" ]; then
            echo "  → Exporting members for $team_slug"
            # Get team members
            members=$(gh api --hostname "$SOURCE_HOST" "orgs/$SOURCE_ORG/teams/$team_slug/members" --paginate --jq --arg team "$team_slug" '[.[] | {
                team: $team,
                username: .login
            }]')
            
            # Get member roles
            for username in $(echo "$members" | jq -r '.[].username'); do
                role=$(gh api --hostname "$SOURCE_HOST" "orgs/$SOURCE_ORG/teams/$team_slug/memberships/$username" --jq '.role')
                member_data=$(jq -n --arg team "$team_slug" --arg user "$username" --arg role "$role" '{
                    team: $team,
                    username: $user,
                    role: $role
                }')
                memberships_data=$(echo "$memberships_data [$member_data]" | jq -s 'add')
            done
        else
            if [ "$has_idp" = "true" ]; then
                echo "  → Skipping members (IdP-managed team)"
            else
                echo "  → Skipping members (export mode: $EXPORT_MODE)"
            fi
        fi
    done
fi

# Combine all data
jq -n \
    --argjson teams "$teams_data" \
    --argjson memberships "$memberships_data" \
    --argjson idp_groups "$idp_groups_data" \
    --arg mode "$EXPORT_MODE" \
    '{teams: $teams, memberships: $memberships, idp_groups: $idp_groups, export_mode: $mode}' > teams-export.json

echo ""
echo "✓ Exported $(echo "$teams_data" | jq 'length') teams"
echo "✓ Exported $(echo "$memberships_data" | jq 'length') manual memberships"
echo "✓ Exported $(echo "$idp_groups_data" | jq 'length') IdP group mappings"
echo "✓ Export mode: $EXPORT_MODE"
echo "✓ Data saved to teams-export.json"
