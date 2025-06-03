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

# Enhanced function to download CivitAI assets with robust metadata handling
# This function will now also retry its own attempts to fetch metadata or download files.
download_civit_model() {
  local model_version_id=$1
  local target_dir=$2
  local max_download_retries=10 # More retries for actual download
  local download_retry_count=0
  local download_success=false

  # Create target directory
  mkdir -p "$target_dir" || { echo "ERROR: Failed to create directory $target_dir"; return 1; }
  
  while [ $download_retry_count -lt $max_download_retries ] && [ "$download_success" = false ]; do
    echo "Attempt $((download_retry_count + 1))/$max_download_retries to download model version $model_version_id..."

    local api_response
    local api_status
    api_response=$(curl -s -w "%{http_code}" -H "Authorization: Bearer $CIVITAI_TOKEN" \
      "https://civitai.com/api/v1/model-versions/$model_version_id")
    
    api_status=${api_response: -3}
    local metadata=${api_response:0:${#api_response}-3}
    
    if [[ $api_status != "200" ]]; then
      echo "ERROR: Failed to get metadata for model $model_version_id (HTTP $api_status)"
      echo "API Response: $metadata"
      download_retry_count=$((download_retry_count + 1))
      sleep 15 # Longer sleep for API errors
      continue
    fi
    
    # Validate JSON response
    if ! echo "$metadata" | jq . > /dev/null 2>&1; then
      echo "ERROR: Invalid JSON response for model $model_version_id metadata fetch."
      download_retry_count=$((download_retry_count + 1))
      sleep 15
      continue
    fi
    
    # Extract model info with explicit error handling
    local model_name=$(echo "$metadata" | jq -r '.model.name // "unknown"')
    local version_name=$(echo "$metadata" | jq -r '.name // "unknown"')
    local model_type=$(echo "$metadata" | jq -r '.model.type // "unknown"')
    
    echo "Model info: '$model_name' version '$version_name' (type: $model_type)"
    
    if [[ "$model_name" == "null" || "$model_name" == "unknown" ]]; then
      echo "ERROR: Could not determine model name for $model_version_id from metadata."
      download_retry_count=$((download_retry_count + 1))
      sleep 15
      continue
    fi
    
    # Extract file info
    local primary_file=$(echo "$metadata" | jq -r '.files[] | select(.primary) | .name')
    local download_url=$(echo "$metadata" | jq -r '.files[] | select(.primary) | .downloadUrl')
    local preview_image=$(echo "$metadata" | jq -r '.images[0].url // ""')
    
    # Check if primary_file or download_url is null or empty
    if [[ -z "$primary_file" || "$primary_file" == "null" || -z "$download_url" || "$download_url" == "null" ]]; then
      echo "ERROR: Could not determine primary file name or download URL for model $model_version_id."
      download_retry_count=$((download_retry_count + 1))
      sleep 15
      continue
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
      download_success=true # Set success flag
    else
      echo "ERROR: Failed to download model file for $model_version_id. Retrying..."
      download_retry_count=$((download_retry_count + 1))
      sleep 30 # Longer sleep for download failures
      continue
    fi

    # If model file downloaded successfully, proceed with other files
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
    
    # For LoRAs, create a .civitai.info file compatible with sd-civitai-browser-plus
    if [[ "$target_dir" == "$LORA_DIR" ]]; then
      local trained_words=$(echo "$metadata" | jq -r '.trainedWords // [] | join(", ")')
      if [[ -n "$trained_words" && "$trained_words" != "null" ]]; then
        echo "Saving trigger words for LoRA: $trained_words"
      else
        echo "Warning: No trigger words found for LoRA $model_version_id"
      fi
      # Create .civitai.info file with full metadata for compatibility
      echo "$metadata" > "$target_dir/${base_filename}.civitai.info"
    fi
  done # End of download retry loop

  if [ "$download_success" = false ]; then
    echo "CRITICAL ERROR: Failed to process/download model $model_version_id after $max_download_retries attempts."
    return 1 # Indicate failure
  fi

  echo "Successfully processed model $model_version_id: $model_name ($version_name)"
  return 0
}

# Install extensions with error resilience
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
        echo "WARNING: Failed to clone $repo_name. Retrying in 10 seconds..."
        retry_count=$((retry_count + 1))
        sleep 10
      fi
    else
      echo "Extension already installed: $repo_name"
      success=true
    fi
  done

  if [ "$success" = false ]; then
    echo "CRITICAL ERROR: Failed to install extension $repo_name after $max_retries attempts. Halting startup."
    exit 1
  fi
}

# Generic function to download files with persistent retries
download_file_with_retries() {
  local url=$1
  local output_path=$2
  local max_retries=10 # More retries for general file downloads
  local retry_count=0
  local success=false

  mkdir -p "$(dirname "$output_path")" # Ensure target directory exists

  while [ $retry_count -lt $max_retries ] && [ "$success" = false ]; do
    echo "Attempt $((retry_count + 1))/$max_retries to download $url to $output_path"
    if curl -fL -o "$output_path" "$url"; then
      echo "Successfully downloaded $output_path"
      success=true
    else
      echo "WARNING: Failed to download $url. Retrying in 15 seconds..."
      retry_count=$((retry_count + 1))
      sleep 15
    fi
  done

  if [ "$success" = false ]; then
    echo "CRITICAL ERROR: Failed to download $output_path after $max_retries attempts. Halting startup."
    exit 1
  fi
}

# Main function to ensure all models/LoRAs are installed with persistent retries
ensure_civitai_asset_installed() {
  local model_version_id=$1
  local target_dir=$2
  local max_installation_retries=3 # Retries for the entire check_model_installed process
  local installation_retry_count=0
  local installed_successfully=false

  while [ $installation_retry_count -lt $max_installation_retries ] && [ "$installed_successfully" = false ]; do
    echo "--- Checking and ensuring installation of CivitAI asset $model_version_id (Attempt $((installation_retry_count + 1))/$max_installation_retries) ---"
    
    # Try to download the model, the download_civit_model function itself has retries
    if download_civit_model "$model_version_id" "$target_dir"; then
      echo "CivitAI asset $model_version_id downloaded successfully."
      installed_successfully=true
    else
      echo "WARNING: Initial attempt to download/process CivitAI asset $model_version_id failed. Retrying entire installation process."
      installation_retry_count=$((installation_retry_count + 1))
      sleep 60 # Longer sleep before starting the entire download process again
    fi
  done

  if [ "$installed_successfully" = false ]; then
    echo "CRITICAL ERROR: Failed to ensure installation of CivitAI asset $model_version_id after $max_installation_retries full attempts. Halting startup."
    exit 1
  fi
}


# -------------------- Main Execution -------------------- #

echo "Starting provisioning script for Forge UI customization with persistent retries..."

# Download custom ui-config.json with retries
echo "Downloading custom ui-config.json..."
download_file_with_retries "https://raw.githubusercontent.com/tamnhucanh/vast-provisioning-scripts/refs/heads/main/ui-config.json" "$FORGE_PATH/ui-config.json"

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
download_file_with_retries "https://huggingface.co/lllyasviel/ControlNet-v1-1/resolve/main/control_v11p_sd15_canny.pth" "$FORGE_PATH/extensions/sd-webui-controlnet/models/control_v11p_sd15_canny.pth"
download_file_with_retries "https://huggingface.co/lllyasviel/ControlNet-v1-1/resolve/main/control_v11p_sd15_openpose.pth" "$FORGE_PATH/extensions/sd-webui-controlnet/models/control_v11p_sd15_openpose.pth"

# VAE installation
mkdir -p "$FORGE_PATH/models/VAE"
download_file_with_retries "https://huggingface.co/stabilityai/sdxl-vae/resolve/main/sdxl_vae.safetensors" "$FORGE_PATH/models/VAE/sdxl_vae.safetensors"

# Download base models - NO HARDCODED NAMES, all from API
echo "=== Downloading base models ==="
ensure_civitai_asset_installed 1166878 "$MODEL_DIR"
ensure_civitai_asset_installed 1761560 "$MODEL_DIR"

# Download LoRAs - NO HARDCODED NAMES, all from API
echo "=== Downloading LoRAs ==="
ensure_civitai_asset_installed 1568786 "$LORA_DIR"
ensure_civitai_asset_installed 1074877 "$LORA_DIR"
ensure_civitai_asset_installed 1486082 "$LORA_DIR"
ensure_civitai_asset_installed 1360425 "$LORA_DIR"
ensure_civitai_asset_installed 1470544 "$LORA_DIR"
ensure_civitai_asset_installed 1674551 "$LORA_DIR"
ensure_civitai_asset_installed 999582 "$LORA_DIR"
ensure_civitai_asset_installed 1364444 "$LORA_DIR"
ensure_civitai_asset_installed 1458421 "$LORA_DIR"
ensure_civitai_asset_installed 960678 "$LORA_DIR"

echo "Provisioning completed successfully! All models and LoRAs verified in $MODEL_DIR and $LORA_DIR"
