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

# Function to sanitize filenames
sanitize() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | tr ' ' '_' | tr -cd '[:alnum:]._-'
}

# ====================== ONLY THIS FUNCTION MODIFIED =====================
download_civit_model() {
  local model_version_id=$1
  local target_dir=$2
  local max_download_retries=10
  local download_retry_count=0
  local download_success=false

  mkdir -p "$target_dir" || { echo "ERROR: Failed to create directory $target_dir"; return 1; }
  
  while [ $download_retry_count -lt $max_download_retries ] && [ "$download_success" = false ]; do
    echo "Attempt $((download_retry_count + 1))/$max_download_retries to download model version $model_version_id..."

    local api_response
    local api_status
    api_response=$(curl -s -w "%{http_code}" -H "Authorization: Bearer $CIVITAI_TOKEN" \
      "https://civitai.com/api/v1/model-versions/$model_version_id")
    
    api_status=${api_response: -3}
    local metadata=${api_response:0:${#api_response}-3}
    
    # Permanent skip if model version is gone (404)
    if [[ $api_status == "404" ]]; then
      echo "ERROR: Model version $model_version_id no longer exists (HTTP 404) — skipping this asset permanently."
      return 1
    fi

    if [[ $api_status != "200" ]]; then
      echo "ERROR: Failed to get metadata for model $model_version_id (HTTP $api_status)"
      echo "API Response: $metadata"
      download_retry_count=$((download_retry_count + 1))
      sleep 7
      continue
    fi
    
    # Validate JSON response
    if ! echo "$metadata" | jq . > /dev/null 2>&1; then
      echo "ERROR: Invalid JSON response for model $model_version_id metadata fetch."
      download_retry_count=$((download_retry_count + 1))
      sleep 7
      continue
    fi
    
    # Extract model info
    local model_name=$(echo "$metadata" | jq -r '.model.name // "unknown"')
    local version_name=$(echo "$metadata" | jq -r '.name // "unknown"')
    local model_type=$(echo "$metadata" | jq -r '.model.type // "unknown"')
    
    echo "Model info: '$model_name' version '$version_name' (type: $model_type)"
    
    if [[ "$model_name" == "null" || "$model_name" == "unknown" ]]; then
      echo "ERROR: Could not determine model name for $model_version_id from metadata."
      download_retry_count=$((download_retry_count + 1))
      sleep 7
      continue
    fi
    
    # Extract file info — fixed selector (was missing == true)
    local primary_file=$(echo "$metadata" | jq -r '.files[] | select(.primary == true) | .name')
    local download_url=$(echo "$metadata" | jq -r '.files[] | select(.primary == true) | .downloadUrl')
    local preview_image=$(echo "$metadata" | jq -r '.images[0].url // ""')
    
    # CRITICAL FIX: Skip if no valid download URL (deleted/private file)
    if [[ -z "$download_url" || "$download_url" == "null" || "$download_url" == "" ]]; then
      echo "ERROR: No valid download URL for model version $model_version_id (file deleted or private) — skipping permanently."
      return 1
    fi

    if [[ -z "$primary_file" || "$primary_file" == "null" ]]; then
      echo "ERROR: Could not determine primary file name for model $model_version_id — skipping permanently."
      return 1
    fi

    # Sanitize names
    local safe_model_name=$(sanitize "$model_name")
    local safe_version_name=$(sanitize "$version_name")
    local base_filename="${safe_model_name}_${safe_version_name}"
    local expected_model_file="$target_dir/${base_filename}.${primary_file##*.}"
    
    echo "Using filename base: $base_filename"
    
    # Save raw JSON metadata
    echo "$metadata" > "$target_dir/${base_filename}.json"
    
    # Download model file
    echo "Downloading model file: $base_filename to $expected_model_file"
    if curl -fL -H "Authorization: Bearer $CIVITAI_TOKEN" -o "$expected_model_file" "$download_url"; then
      echo "Successfully downloaded model file for $model_version_id."
      download_success=true
    else
      echo "ERROR: Failed to download model file for $model_version_id. Retrying..."
      rm -f "$expected_model_file"  # clean partial download
      download_retry_count=$((download_retry_count + 1))
      sleep 7
      continue
    fi

    # Save description
    local description_html=$(echo "$metadata" | jq -r '.description // ""')
    echo "$description_html" > "$target_dir/${base_filename}.html"
    
    # Download preview image
    if [[ -n "$preview_image" && "$preview_image" != "null" ]]; then
      curl -fL -o "$target_dir/${base_filename}.preview.png" \
        "$preview_image" || echo "Warning: Failed to download preview image for $model_version_id"
    else
      echo "Warning: No preview image available for $model_version_id"
    fi
    
    # For LoRAs, create .civitai.info file
    if [[ "$target_dir" == "$LORA_DIR" ]]; then
      local trained_words=$(echo "$metadata" | jq -r '.trainedWords // [] | join(", ")')
      echo "$metadata" > "$target_dir/${base_filename}.civitai.info"
    fi
  done

  if [ "$download_success" = false ]; then
    echo "WARNING: Failed to download model $model_version_id after $max_download_retries attempts — skipping this asset."
    return 1
  fi

  echo "Successfully processed model $model_version_id: $model_name ($version_name)"
  return 0
}

# ====================== ONLY THIS FUNCTION MODIFIED (non-fatal on skip) =====================
ensure_civitai_asset_installed() {
  local model_version_id=$1
  local target_dir=$2
  local max_installation_retries=3
  local installation_retry_count=0

  while [ $installation_retry_count -lt $max_installation_retries ]; do
    if download_civit_model "$model_version_id" "$target_dir"; then
      return 0
    else
      installation_retry_count=$((installation_retry_count + 1))
      echo "WARNING: Retry $installation_retry_count/$max_installation_retries for asset $model_version_id"
      sleep 7
    fi
  done

  echo "ERROR: Skipping CivitAI asset $model_version_id after multiple failures (likely deleted/private)."
  return 1  # Non-fatal — continue with other assets
}

# ====================== download_file_with_retries — now 7s + non-fatal =====================
download_file_with_retries() {
  local url=$1
  local output_path=$2
  local max_retries=10
  local retry_count=0

  mkdir -p "$(dirname "$output_path")"

  while [ $retry_count -lt $max_retries ]; do
    echo "Attempt $((retry_count + 1))/$max_retries to download $url to $output_path"
    if curl -fL -o "$output_path" "$url"; then
      echo "Successfully downloaded $output_path"
      return 0
    else
      echo "WARNING: Failed to download $url. Retrying in 7 seconds..."
      rm -f "$output_path"
      retry_count=$((retry_count + 1))
      sleep 7
    fi
  done

  echo "ERROR: Skipping $output_path after $max_retries failed attempts."
  return 1
}

# Keep your original install_extension (unchanged except sleep 7)
install_extension() {
  local repo_url=$1
  local repo_name=$(basename "$repo_url" .git)
  local target_dir="$FORGE_PATH/extensions/$repo_name"
  local max_retries=5
  local retry_count=0
  local success=false

  while [ $retry_count -lt $max_retries ] && [ "$success" = false ]; do
    if [ ! -d "$target_dir" ]; then
      echo "Attempt $((retry_count + 1))/$max_retries to install extension: $repo_name"
      if git clone "$repo_url" "$target_dir"; then
        echo "Successfully installed extension: $repo_name"
        success=true
      else
        echo "WARNING: Failed to clone $repo_name. Retrying in 7 seconds..."
        retry_count=$((retry_count + 1))
        sleep 7
      fi
    else
      echo "Extension already installed: $repo_name"
      success=true
    fi
  done

  if [ "$success" = false ]; then
    echo "WARNING: Could not install extension $repo_name — continuing anyway."
  fi
}

# -------------------- Main Execution (now fully resilient) -------------------- #

echo "Starting provisioning script..."

download_file_with_retries "https://raw.githubusercontent.com/tamnhucanh/vast-provisioning-scripts/refs/heads/main/ui-config.json" "$FORGE_PATH/ui-config.json" || true

install_extension "https://github.com/Mikubill/sd-webui-controlnet.git" || true
install_extension "https://github.com/camenduru/sd-webui-additional-networks.git" || true
install_extension "https://github.com/AlUlkesh/stable-diffusion-webui-images-browser.git" || true
install_extension "https://github.com/DominikDoom/a1111-sd-webui-tagcomplete.git" || true
install_extension "https://github.com/adieyal/sd-dynamic-prompts.git" || true
install_extension "https://github.com/Bing-su/adetailer.git" || true
install_extension "https://github.com/BlafKing/sd-civitai-browser-plus.git" || true

mkdir -p "$FORGE_PATH/extensions/sd-webui-controlnet/models"
download_file_with_retries "https://huggingface.co/lllyasviel/ControlNet-v1-1/resolve/main/control_v11p_sd15_canny.pth" "$FORGE_PATH/extensions/sd-webui-controlnet/models/control_v11p_sd15_canny.pth" || true
download_file_with_retries "https://huggingface.co/lllyasviel/ControlNet-v1-1/resolve/main/control_v11p_sd15_openpose.pth" "$FORGE_PATH/extensions/sd-webui-controlnet/models/control_v11p_sd15_openpose.pth" || true

mkdir -p "$FORGE_PATH/models/VAE"
download_file_with_retries "https://huggingface.co/stabilityai/sdxl-vae/resolve/main/sdxl_vae.safetensors" "$FORGE_PATH/models/VAE/sdxl_vae.safetensors" || true

echo "=== Downloading base models (missing ones will be skipped) ==="
ensure_civitai_asset_installed 1166878 "$MODEL_DIR" || echo "Skipped base model 1166878 (no longer available)"
ensure_civitai_asset_installed 1761560 "$MODEL_DIR" || echo "Skipped base model 1761560 (no longer available)"

echo "=== Downloading LoRAs (missing ones will be skipped) ==="
ensure_civitai_asset_installed 1568786 "$LORA_DIR" || echo "Skipped LoRA 1568786"
ensure_civitai_asset_installed 1074877 "$LORA_DIR" || echo "Skipped LoRA 1074877"
ensure_civitai_asset_installed 1486082 "$LORA_DIR" || echo "Skipped LoRA 1486082"
ensure_civitai_asset_installed 1360425 "$LORA_DIR" || echo "Skipped LoRA 1360425"
ensure_civitai_asset_installed 1470544 "$LORA_DIR" || echo "Skipped LoRA 1470544"
ensure_civitai_asset_installed 1674551 "$LORA_DIR" || echo "Skipped LoRA 1674551"
ensure_civitai_asset_installed 999582 "$LORA_DIR" || echo "Skipped LoRA 999582"
ensure_civitai_asset_installed 1458421 "$LORA_DIR" || echo "Skipped LoRA 1458421"
ensure_civitai_asset_installed 960678 "$LORA_DIR" || echo "Skipped LoRA 960678"

echo "Provisioning completed! Any deleted/unavailable models were automatically skipped."
