#!/bin/bash

# Function to escape label values
escape_label_value() {
    local val="$1"
    val="${val//\\/\\\\}"  # Escape backslash
    val="${val//\"/\\\"}"  # Escape double quote
    val="${val//$'\n'/}"   # Remove newlines
    val="${val//$'\r'/}"   # Remove carriage returns
    echo -n "$val"
}

# Function to add metrics without duplication
metric_add() {
    local metric="$1"
    if ! grep -Fxq "$metric" "$METRICS_FILE"; then
        echo "$metric" >> "$METRICS_FILE"
        echo "$metric"
    else
        echo "Duplicate metric found, not adding: $metric" >&2
    fi
}

# Function to handle API requests without logging
safe_curl() {
    local url="$1"
    local method="${2:-GET}"
    local data="${3:-}"
    shift 3
    local headers=("$@")

    # Prefix each header with -H
    local curl_headers=()
    for header in "${headers[@]}"; do
        curl_headers+=("-H" "$header")
    done

    response=$(curl -k -s -f -X "$method" "${curl_headers[@]}" "$url" -d "$data")
    local exit_status=$?
    if [[ $exit_status -eq 0 ]]; then
        echo "$response"
        return 0
    else
        # Return empty response on failure
        return 1
    fi
}

# Function to check if a pod's service account has access to the Kubernetes API
check_pod_api_access() {
    local pod_name="$1"
    local namespace="$2"

    # Get the service account name for the pod
    service_account_name=$(safe_curl "$KUBE_API/api/v1/namespaces/$namespace/pods/$pod_name" "GET" "" \
        "-H" "Authorization: Bearer $SA_TOKEN" "-H" "Content-Type: application/json" | jq -r '.spec.serviceAccountName')

    if [[ -z "$service_account_name" ]]; then
        metric_add "k8s_pod_api_access{namespace=\"$(escape_label_value "$namespace")\", pod=\"$(escape_label_value "$pod_name")\"} 0"
        return
    fi

    # Fetch the service account token from the secret
    secret_name=$(safe_curl "$KUBE_API/api/v1/namespaces/$namespace/serviceaccounts/$service_account_name" "GET" "" \
        "-H" "Authorization: Bearer $SA_TOKEN" "-H" "Content-Type: application/json" | jq -r '.secrets[0].name')

    if [[ -z "$secret_name" ]]; then
        metric_add "k8s_pod_api_access{namespace=\"$(escape_label_value "$namespace")\", pod=\"$(escape_label_value "$pod_name")\"} 0"
        return
    fi

    # Get the actual service account token
    pod_sa_token=$(safe_curl "$KUBE_API/api/v1/namespaces/$namespace/secrets/$secret_name" "GET" "" \
        "-H" "Authorization: Bearer $SA_TOKEN" "-H" "Content-Type: application/json" | jq -r '.data.token' | base64 --decode)

    if [[ -z "$pod_sa_token" ]]; then
        metric_add "k8s_pod_api_access{namespace=\"$(escape_label_value "$namespace")\", pod=\"$(escape_label_value "$pod_name")\"} 0"
        return
    fi

    # Use the token to attempt an API access check (e.g., list namespaces)
    response=$(safe_curl "$KUBE_API/api/v1/namespaces" "GET" "" \
        "-H" "Authorization: Bearer $pod_sa_token" "-H" "Content-Type: application/json")

    if [[ $? -eq 0 && $response == *"NamespaceList"* ]]; then
        metric_add "k8s_pod_api_access{namespace=\"$(escape_label_value "$namespace")\", pod=\"$(escape_label_value "$pod_name")\"} 1"
    else
        metric_add "k8s_pod_api_access{namespace=\"$(escape_label_value "$namespace")\", pod=\"$(escape_label_value "$pod_name")\"} 0"
    fi
}

# Function to collect metrics once
collect_metrics() {
    # Loop over all namespaces and pods
    namespaces=$(safe_curl "$KUBE_API/api/v1/namespaces" "GET" "" \
        "-H" "Authorization: Bearer $SA_TOKEN" "-H" "Content-Type: application/json" | jq -r '.items[].metadata.name')

    for ns in $namespaces; do
        pods=$(safe_curl "$KUBE_API/api/v1/namespaces/$ns/pods" "GET" "" \
            "-H" "Authorization: Bearer $SA_TOKEN" "-H" "Content-Type: application/json" | jq -r '.items[].metadata.name')
        for pod in $pods; do
            check_pod_api_access "$pod" "$ns"
        done
    done

    # Add a heartbeat metric
    metric_add "k8s_api_access_heartbeat $(date +%s)"
}

# Configuration
KUBE_API="https://kubernetes.default.svc"
SA_TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
CA_CERT="/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
METRICS_FILE="/tmp/metrics.log"
CURRENT_MIN=$((10#$(date +%M)))
RUN_BEFORE_MINUTE=${RUN_BEFORE_MINUTE:-"5"}
EPOCH=$(date +%s)

if [[ $CURRENT_MIN -lt ${RUN_BEFORE_MINUTE} ]]; then
    echo "" > /tmp/metrics.log

    metric_add "# scraping start $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    metric_add "kubernetes_heart_beat ${EPOCH}"
    metric_add "# HELP k8s_pod_api_access Whether a pod has access to the Kubernetes API."
    metric_add "# TYPE k8s_pod_api_access gauge"

    # Collect metrics once
    collect_metrics
fi
