#!/usr/bin/env bash

# Color codes for a professional, visually appealing output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

DNS_SERVER="1.1.1.1"
MY_NS_IDENTIFIER="host.al"       # All your nameservers contain "host.al"
CLOUDFLARE_IDENTIFIER="cloudflare.com"
LOG_FILE="/var/log/domain_check.log"  # Adjust log file path as needed

# Get all domains from Plesk
mapfile -t domains < <(plesk bin domain --list)
total_domains=${#domains[@]}
counter=1

# Categorized domain lists
declare -a pointing_elsewhere cloudflare_here cloudflare_not_here manual_check

# Associative array for grouping domains by normalized host.al nameserver pair
declare -A grouped_pointing_here

# Process each domain (intermediate output will be cleared later)
for domain in "${domains[@]}"; do
    # Retrieve NS records first for display purposes
    ns_records=$(dig @"$DNS_SERVER" +short NS "$domain" 2>/dev/null | grep -vE '^(;|$)' | sort)
    if [[ -z "$ns_records" ]]; then
        ns_display="[No NS records]"
    else
        ns_display=$(echo "$ns_records" | paste -sd " " -)
    fi

    echo "[${counter}/${total_domains}] Processing domain: $domain - ${ns_display}"
    counter=$((counter+1))
    sleep 1  # Avoid overwhelming the system

    # Handle DNS failure/timeout
    if [[ -z "$ns_records" || "$ns_records" =~ (timed\ out|SERVFAIL|unexpected\ error|no\ servers\ could\ be\ reached) ]]; then
        manual_check+=("$domain")
        continue
    fi

    # Format NS records for display in later output (using " | " as separator)
    ns_records_formatted=$(echo "$ns_records" | paste -sd " | " -)

    # If NS records include our host.al identifier, group them by normalized NS pair
    if echo "$ns_records" | grep -q "$MY_NS_IDENTIFIER"; then
        host_ns=$(echo "$ns_records" | grep "$MY_NS_IDENTIFIER" | sed 's/^[ \t]*//;s/[ \t]*$//')
        sorted_host_ns=$(echo "$host_ns" | sort | paste -sd " | " -)
        if [[ -n "${grouped_pointing_here[$sorted_host_ns]}" ]]; then
            grouped_pointing_here["$sorted_host_ns"]+=$'\n'"$domain - $ns_records_formatted"
        else
            grouped_pointing_here["$sorted_host_ns"]="$domain - $ns_records_formatted"
        fi
        continue
    fi

    # Check if domain is using Cloudflare
    if echo "$ns_records" | grep -qi "$CLOUDFLARE_IDENTIFIER"; then
        sleep 1
        # Added '--' to ensure grep does not misinterpret the pattern as an option.
        root_dir=$(plesk bin site --info "$domain" | grep -F -- "--WWW-Root--:" | cut -d':' -f2- | xargs)
        if [[ -z "$root_dir" || ! -d "$root_dir" ]]; then
            cloudflare_not_here+=("$domain - $ns_records_formatted")
            continue
        fi

        CHECK_FILE="${root_dir}/server_check.txt"
        if ! echo "$(hostname)" > "$CHECK_FILE"; then
            manual_check+=("$domain - $ns_records_formatted")
            continue
        fi
        chmod 644 "$CHECK_FILE"

        if curl -skL --max-time 3 "https://$domain/server_check.txt" | grep -q "$(hostname)"; then
            cloudflare_here+=("$domain - $ns_records_formatted")
        elif curl -skL --max-time 3 "http://$domain/server_check.txt" | grep -q "$(hostname)"; then
            cloudflare_here+=("$domain - $ns_records_formatted")
        else
            echo "[$(date)] $domain: Verification file not found via HTTP/HTTPS" >> "$LOG_FILE"
            cloudflare_not_here+=("$domain - $ns_records_formatted")
        fi

        [ -f "$CHECK_FILE" ] && rm -f "$CHECK_FILE"
        continue
    fi

    # Domain points elsewhere
    pointing_elsewhere+=("$domain - $ns_records_formatted")
done

# Clear terminal to display only the final, categorized output
clear

# Display final report header
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}        Domain Check Report           ${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# Function to print a section with a header and a horizontal rule
print_section() {
    local header="$1"
    shift
    echo -e "${GREEN}${header}:${NC}"
    echo "----------------------------------------"
    if [ "$#" -gt 0 ]; then
        # Each element in these arrays doesn't contain newlines.
        printf '   %s\n' "$@" | sort
    else
        echo "   (None)"
    fi
    echo ""
}

# Print grouped domains pointing to this server (by NS pair)
echo -e "${GREEN}Domains Pointing to This Server (Grouped by NS Pair):${NC}"
echo "========================================"
for ns_pair in "${!grouped_pointing_here[@]}"; do
    echo -e "${YELLOW}NS Pair:${NC} $ns_pair"
    echo "----------------------------------------"
    # Split the grouped output into individual lines and sort them
    IFS=$'\n' read -rd '' -a grouped_lines <<< "${grouped_pointing_here[$ns_pair]}"
    printf '%s\n' "${grouped_lines[@]}" | sort | while IFS= read -r line; do
        echo "   $line"
    done
    echo ""
done

# Print other categorized sections
print_section "Domains Pointing Elsewhere" "${pointing_elsewhere[@]}"
print_section "Cloudflare Domains Verified on This Server" "${cloudflare_here[@]}"
print_section "Cloudflare Domains Not Pointing Here" "${cloudflare_not_here[@]}"
print_section "Domains Requiring Manual Check (Possibly Expired, DNS Timeout, or Errors)" "${manual_check[@]}"
