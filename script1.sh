#!/bin/bash
set -eo pipefail

# Set CivitAI API token from environment variable
export CIVITAI_TOKEN="${CIVITAI_TOKEN}"

# Validate token presence
if [ -z "$CIVITAI_TOKEN" ]; then
  echo "ERROR: CivitAI token not found! Set CIVITAI_TOKEN in Vast.ai template."
  exit 1
fi

# Validate dependencies
for cmd in curl jq git xargs; do
  if ! command -v "$cmd" &> /dev/null; then
    echo "ERROR: Required command '$cmd' not found. Please install it."
    exit 1
  fi
done

# Base paths
FORGE_PATH="/workspace/stable-diffusion-webui-forge"
MODEL_DIR="$FORGE_PATH/models/Stable-diffusion"
LORA_DIR="$FORGE_PATH/models/Lora"

# Parallel download settings
MAX_PARALLEL=2      # Reduced to avoid API rate limits
MAX_RETRIES=3       # Maximum retries for failed downloads
RETRY_DELAY=5       # Delay between retries (seconds)
CURL_TIMEOUT=30     # Timeout for curl commands (seconds)

# Array to track download outcomes
declare -A DOWNLOAD_STATUS

# Function to sanitize filenames
sanitize() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | tr ' ' '_' | tr -cd '[:alnum:]._-'
}

# Function to download CivitAI assets with retry logic
download_civit_model() {
  local model_version_id=$1
  local target_dir=$2
  local attempt=1

  # Create target directory
  mkdir -p "$target_dir" || {
    echo "ERROR: Failed to create directory $target_dir for model $model_version_id"
    return 1
  }

  while [ $attempt -le $MAX_RETRIES ]; do
    echo "Attempt $attempt/$MAX_RETRIES: Fetching metadata for model version $model_version_id..."

    # Get model metadata
    local api_response
    local api_status
    api_response=$(curl -s -m "$CURL_TIMEOUT" -w "%{http_code}" -H "Authorization: Bearer $CIVITAI_TOKEN" \
      "https://civitai.com/api/v1/model-versions/$model_version_id" || echo "CURL_FAILED")

    if [[ "$api_response" == "CURL_FAILED" ]]; then
      echo "ERROR: Curl failed for model $model_version_id (timeout or network issue)"
      sleep $RETRY_DELAY
      ((attempt++))
      continue
    fi

    api_status=${api_response: -3}
    local metadata=${api_response:0:${#api_response}-3}

    if [[ $api_status != "200" ]]; then
      echo "ERROR: Failed to get metadata for model $model_version_id (HTTP $api_status)"
      echo "API Response: $metadata"
      sleep $RETRY_DELAY
      ((attempt++))
      continue
    fi

    # Validate JSON response
    if ! echo "$metadata" | jq . > /dev/null 2>&1; then
      echo "ERROR: Invalid JSON response for model $model_version_id"
      sleep $RETRY_DELAY
      ((attempt++))
      continue
    fi

    # Extract model info
    local model_name=$(echo "$metadata" | jq -r '.model.name // "unknown"')
    local version_name=$(echo "$metadata" | jq -r '.name // "unknown"')
    local model_type=$(echo "$metadata" | jq -r '.model.type // "unknown"')

    echo "Model info: '$model_name' version '$version_name' (type: $model_type)"

    if [[ "$model_name" == "null" || "$model_name" == "unknown" ]]; then
      echo "ERROR: Could not determine model name for $model_version_id"
      sleep $RETRY_DELAY
      ((attempt++))
      continue
    fi

    # Extract file info
    local primary_file=$(echo "$metadata" | jq -r '.files[] | select(.primary) | .name // ""')
    local download_url=$(echo "$metadata" | jq -r '.files[] | select(.primary) | .downloadUrl // ""')
    local preview_image=$(echo "$metadata" | jq -r '.images[0].url // ""')

    if [[ -z "$primary_file" || -z "$download_url" ]]; then
      echo "ERROR: No primary file or download URL for $model_version_id"
      sleep $RETRY_DELAY
      ((attempt++))
      continue
    fi

    # Sanitize names
    local safe_model_name=$(sanitize "$model_name")
    local safe_version_name=$(sanitize "$version_name")
    local base_filename="${safe_model_name}_${safe_version_name}"
    local model_file="$target_dir/${base_filename}.${primary_file##*.}"

    echo "Using filename base: $base_filename"

    # Check if model file already exists
    if [ -f "$model_file" ]; then
      echo "Model file already exists: $model_file, skipping download"
      DOWNLOAD_STATUS["$model_version_id"]="Success (already exists)"
      return 0
    fi

    # Save raw JSON metadata
    echo "$metadata" > "$target_dir/${base_filename}.json" || {
      echo "ERROR: Failed to save metadata for $model_version_id"
      return 1
    }

    # Download model file
    echo "Downloading model: $base_filename"
    if curl -fL -m "$CURL_TIMEOUT" -H "Authorization: Bearer $CIVITAI_TOKEN" -o "$model_file" "$download_url"; then
      # Save description
      local description_html=$(echo "$metadata" | jq -r '.description // ""')
      echo "$description_html" > "$target_dir/${base_filename}.html"

      # Download preview image
      if [[ -n "$preview_image" && "$preview_image" != "null" ]]; then
        curl -fL -m "$CURL_TIMEOUT" -o "$target_dir/${base_filename}.preview.png" "$preview_image" || \
          echo "Warning: Failed to download preview image for $model_version_id"
      else
        echo "Warning: No preview image available for $model_version_id"
      fi

      echo "Successfully processed model $model_version_id: $model_name ($version_name)"
      DOWNLOAD_STATUS["$model_version_id"]="Success"
      return 0
    else
      echo "ERROR: Failed to download model file for $model_version_id"
      rm -f "$model_file" # Remove partial download
      sleep $RETRY_DELAY
      ((attempt++))
      continue
    fi
  done

  echo "ERROR: Max retries reached for model $model_version_id"
  DOWNLOAD_STATUS["$model_version_id"]="Failed (max retries reached)"
  return 1
}

# Wrapper function for xargs
download_model_wrapper() {
  local id=$1
  local target_dir
  local model_id

  # Determine if it's a model or LoRA based on prefix
  if [[ "${id:0:1}" == "m" ]]; then
    target_dir="$MODEL_DIR"
    model_id="${id:1}"
  else
    target_dir="$LORA_DIR"
    model_id="${id:1}"
  fi

  download_civit_model "$model_id" "$target_dir" && \
    echo "Completed download of $id" || \
    echo "Failed download of $id"
}

export -f download_civit_model download_model_wrapper sanitize
export CIVITAI_TOKEN MODEL_DIR LORA_DIR MAX_RETRIES RETRY_DELAY CURL_TIMEOUT DOWNLOAD_STATUS

# Function to download multiple models in parallel using xargs
download_batch() {
  local ids=("$@")

  echo "Starting parallel download of ${#ids[@]} models/LoRAs..."
  printf "%s\n" "${ids[@]}" | xargs -n 1 -P "$MAX_PARALLEL" -I {} bash -c 'download_model_wrapper "{}"'

  # Print summary of download outcomes
  echo "=== Download Summary ==="
  for id in "${ids[@]}"; do
    model_id="${id:1}"
    status="${DOWNLOAD_STATUS[$model_id]:-Not attempted}"
    echo "$id: $status"
  done
}

# Install extensions with error resilience
install_extension() {
  local repo_url=$1
  local repo_name=$(basename "$repo_url" .git)
  local target_dir="$FORGE_PATH/extensions/$repo_name"

  if [ ! -d "$target_dir" ]; then
    echo "Installing extension: $repo_name"
    git clone "$repo_url" "$target_dir" || echo "Warning: Failed to clone $repo_name"
  else
    echo "Extension already installed: $repo_name"
  fi
}

# -------------------- Main Execution -------------------- #

echo "Starting provisioning script for Forge UI customization..."

# Install original extensions
install_extension "https://github.com/Mikubill/sd-webui-controlnet.git"
install_extension "https://github.com/camenduru/sd-webui-additional-networks.git"
install_extension "https://github.com/AlUlkesh/stable-diffusion-webui-images-browser.git"

# Install custom extensions
install_extension "https://github.com/DominikDoom/a1111-sd-webui-tagcomplete.git"
install_extension "https://github.com/adieyal/sd-dynamic-prompts.git"
install_extension "https://github.com/Bing-su/adetailer.git"
install_extension "https://github.com/BlafKing/sd-civitai-browser-plus.git"

# ControlNet models setup
mkdir -p "$FORGE_PATH/extensions/sd-webui-controlnet/models"
cd "$FORGE_PATH/extensions/sd-webui-controlnet/models"
wget -nc https://huggingface.co/lllyasviel/ControlNet-v1-1/resolve/main/control_v11p_sd15_canny.pth
wget -nc https://huggingface.co/lllyasviel/ControlNet-v1-1/resolve/main/control_v11p_sd15_openpose.pth

# VAE installation
mkdir -p "$FORGE_PATH/models/VAE"
cd "$FORGE_PATH/models/VAE"
wget -nc https://huggingface.co/stabilityai/sdxl-vae/resolve/main/sdxl_vae.safetensors

# Download models and LoRAs with parallel processing (prefix m=model, l=lora)
echo "=== Downloading models and LoRAs in parallel (max $MAX_PARALLEL) ==="
