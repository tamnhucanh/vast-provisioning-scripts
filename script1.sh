#!/bin/bash
set -eo pipefail

# Set CivitAI API token from environment variable
export CIVITAI_TOKEN="${CIVITAI_TOKEN}"

# Validate token presence
if [ -z "$CIVITAI_TOKEN" ]; then
  echo "ERROR: CivitAI token not found! Set CIVITAI_TOKEN in Vast.ai template."
  exit 1
fi

# Base paths
FORGE_PATH="/workspace/stable-diffusion-webui-forge"
MODEL_DIR="$FORGE_PATH/models/Stable-diffusion"
LORA_DIR="$FORGE_PATH/models/Lora"

# Parallel download settings
MAX_PARALLEL=4      # Maximum number of concurrent downloads

# Function to sanitize filenames
sanitize() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | tr ' ' '_' | tr -cd '[:alnum:]._-'
}

# Function to download CivitAI assets with robust metadata handling
download_civit_model() {
  local model_version_id=$1
  local target_dir=$2

  # Create target directory
  mkdir -p "$target_dir" || return 1

  # Get model metadata with explicit API call and error checking
  echo "Fetching metadata for model version $model_version_id..."

  local api_response
  local api_status
  api_response=$(curl -s -w "%{http_code}" -H "Authorization: Bearer $CIVITAI_TOKEN" \
    "https://civitai.com/api/v1/model-versions/$model_version_id")

  api_status=${api_response: -3}
  local metadata=${api_response:0:${#api_response}-3}

  if [[ $api_status != "200" ]]; then
    echo "ERROR: Failed to get metadata for model $model_version_id (HTTP $api_status)"
    echo "API Response: $metadata"
    return 1
  fi

  # Validate JSON response
  if ! echo "$metadata" | jq . > /dev/null 2>&1; then
    echo "ERROR: Invalid JSON response for model $model_version_id"
    return 1
  fi

  # Extract model info with explicit error handling
  local model_name=$(echo "$metadata" | jq -r '.model.name // "unknown"')
  local version_name=$(echo "$metadata" | jq -r '.name // "unknown"')
  local model_type=$(echo "$metadata" | jq -r '.model.type // "unknown"')

  echo "Model info: '$model_name' version '$version_name' (type: $model_type)"

  if [[ "$model_name" == "null" || "$model_name" == "unknown" ]]; then
    echo "ERROR: Could not determine model name for $model_version_id"
    return 1
  fi

  # Extract file info
  local primary_file=$(echo "$metadata" | jq -r '.files[] | select(.primary) | .name')
  local download_url=$(echo "$metadata" | jq -r '.files[] | select(.primary) | .downloadUrl')
  local preview_image=$(echo "$metadata" | jq -r '.images[0].url // ""')

  # Sanitize names
  local safe_model_name=$(sanitize "$model_name")
  local safe_version_name=$(sanitize "$version_name")
  local base_filename="${safe_model_name}_${safe_version_name}"

  echo "Using filename base: $base_filename"

  # Save raw JSON metadata
  echo "$metadata" > "$target_dir/${base_filename}.json"

  # Download model file
  echo "Downloading model: $base_filename"
  curl -fL -H "Authorization: Bearer $CIVITAI_TOKEN" \
    -o "$target_dir/${base_filename}.${primary_file##*.}" \
    "$download_url" || {
      echo "ERROR: Failed to download model file for $model_version_id"
      return 1
    }

  # Save description
  local description_html=$(echo "$metadata" | jq -r '.description // ""')
  echo "$description_html" > "$target_dir/${base_filename}.html"

  # Download preview image
  if [[ -n "$preview_image" && "$preview_image" != "null" ]]; then
    curl -fL -o "$target_dir/${base_filename}.preview.png" \
      "$preview_image" || echo "Warning: Failed to download preview image"
  else
    echo "Warning: No preview image available for $model_version_id"
  fi

  echo "Successfully processed model $model_version_id: $model_name ($version_name)"
  return 0
}

# Function to download multiple models in parallel using background processes
download_batch() {
  local ids=("$@")
  local running=0

  for id in "${ids[@]}"; do
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

    # Process in background
    (download_civit_model "$model_id" "$target_dir" && \
     echo "Completed download of $id") &

    # Track running jobs
    ((running++))

    # Limit parallelism
    if (( running >= MAX_PARALLEL )); then
      wait -n
      ((running--))
    fi
  done

  # Wait for all remaining downloads to complete
  wait
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
download_batch \
  "m1166878" "m1612720" "m1111838" \
  "l1568786" "l1074877" "l1486082" "l1360425" "l1470544" "l1645427" "l999582" "l1364444" "l1458421"

echo "Provisioning completed successfully! Check $MODEL_DIR and $LORA_DIR"
