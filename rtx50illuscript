#!/bin/bash

# ====================================================================================
#  GLOBAL ERROR HANDLING
# ====================================================================================
set -euo pipefail
trap 'echo "🚨 SCRIPT CRASHED on line $LINENO: The provisioning script encountered a critical error. Stopping further execution." >&2' ERR

# --- CONFIGURATION ---
USER_AGENT="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
export CIVITAI_TOKEN="${CIVITAI_TOKEN}"

# Validate token presence
if [ -z "$CIVITAI_TOKEN" ]; then
  echo "ERROR: CivitAI token not found! Set CIVITAI_TOKEN in your environment variables."
  exit 1
fi

# Base paths (We use /workspace for persistent storage)
FORGE_PATH="/workspace/stable-diffusion-webui-forge"
MODEL_DIR="$FORGE_PATH/models/Stable-diffusion"
LORA_DIR="$FORGE_PATH/models/Lora"

# --- SYSTEM DEPENDENCY FIXES (Moved from Arg 2 to here) ---
echo "--- Installing missing system dependencies ---"
apt-get update -y
# Install required libs for OpenCV, ControlNet, and script utilities
apt-get install -y pkg-config libcairo2-dev build-essential libgirepository1.0-dev libgl1-mesa-glx libsm6 libxext6 curl file socat

# --- PYTHON DEPENDENCY FIXES ---
echo "--- Installing missing Python libraries ---"
pip install joblib

# Function to sanitize filenames
sanitize() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | tr ' ' '_' | tr -cd '[:alnum:]._-'
}

# ====================================================================================
#  CORE FUNCTION: Bulletproof Civitai Downloader
# ====================================================================================
download_civit_model() {
  local model_version_id=$1
  local target_dir=$2
  local max_download_retries=5
  local download_retry_count=0
  local download_success=false
  
  mkdir -p "$target_dir" || { echo "ERROR: Failed to create directory $target_dir"; return 1; }

  while [ $download_retry_count -lt $max_download_retries ] && [ "$download_success" = false ]; do
    echo "Attempt $((download_retry_count + 1))/$max_download_retries for Model ID $model_version_id..."

    # STEP A: Try Metadata API
    local api_response
    set +e 
    api_response=$(curl -s -A "$USER_AGENT" -H "Authorization: Bearer $CIVITAI_TOKEN" "https://civitai.com/api/v1/model-versions/$model_version_id")
    set -e
    
    if echo "$api_response" | jq -e .model.name >/dev/null 2>&1; then
      local model_name=$(echo "$api_response" | jq -r '.model.name // "unknown"')
      local version_name=$(echo "$api_response" | jq -r '.name // "unknown"')
      local primary_file=$(echo "$api_response" | jq -r '.files[] | select(.primary == true) | .name')
      local download_url=$(echo "$api_response" | jq -r '.files[] | select(.primary == true) | .downloadUrl')
      local preview_image=$(echo "$api_response" | jq -r '.images[0].url // ""')

      if [[ -z "$download_url" || "$download_url" == "null" ]]; then
          echo "WARNING: Metadata found but no download URL."
          api_response="INVALID" 
      else
          local safe_name=$(sanitize "$model_name")
          local safe_ver=$(sanitize "$version_name")
          local filename="${safe_name}_${safe_ver}.${primary_file##*.}"
          
          echo "Metadata found: $model_name ($version_name). Downloading..."
          
          if curl -L -A "$USER_AGENT" -H "Authorization: Bearer $CIVITAI_TOKEN" -o "$target_dir/$filename" "$download_url"; then
            echo "$api_response" > "$target_dir/${filename%.*}.json"
            if [[ -n "$preview_image" && "$preview_image" != "null" ]]; then
              curl -sL -A "$USER_AGENT" -o "$target_dir/${filename%.*}.preview.png" "$preview_image" || true
            fi
            download_success=true
          fi
      fi
    fi

    # STEP B: Direct Fallback
    if [ "$download_success" = false ]; then
      echo "WARNING: Metadata API failed. Attempting BLIND DIRECT DOWNLOAD..."
      pushd "$target_dir" > /dev/null
      set +e
      if curl -L -J -O -A "$USER_AGENT" -H "Authorization: Bearer $CIVITAI_TOKEN" "https://civitai.com/api/download/models/$model_version_id"; then
        download_success=true
      fi
      set -e
      popd > /dev/null
    fi

    # STEP C: Validation
    if [ "$download_success" = true ]; then
      local downloaded_file=$(ls -t "$target_dir" | head -n1)
      local file_path="$target_dir/$downloaded_file"
      
      if file "$file_path" | grep -q "HTML"; then
        echo "ERROR: Downloaded file is an HTML Cloudflare Block page. Deleting."
        rm -f "$file_path"
        download_success=false
        sleep 5
      elif [ ! -s "$file_path" ]; then
          echo "ERROR: Downloaded file is empty."
          rm -f "$file_path"
          download_success=false
      else
        echo "SUCCESS: Downloaded $downloaded_file"
        return 0
      fi
    fi

    download_retry_count=$((download_retry_count + 1))
    echo "Retrying in 5 seconds..."
    sleep 5
  done

  echo "FAILURE: Could not download model $model_version_id."
  return 1 
}

ensure_civitai_asset_installed() {
  local model_version_id=$1
  local target_dir=$2
  
  if download_civit_model "$model_version_id" "$target_dir"; then
    return 0
  else
    echo "ERROR: Permanently skipped CivitAI asset $model_version_id (Failed)."
    return 0 
  fi
}

download_file_with_retries() {
  local url=$1
  local output_path=$2
  local max_retries=5
  local retry_count=0
  
  mkdir -p "$(dirname "$output_path")"
  
  while [ $retry_count -lt $max_retries ]; do
    if curl -fL -A "$USER_AGENT" -o "$output_path" "$url"; then
      echo "Successfully downloaded $output_path"
      return 0
    else
      echo "WARNING: Failed to download $url. Retrying..."
      rm -f "$output_path"
      retry_count=$((retry_count + 1))
      sleep 5
    fi
  done
  echo "ERROR: Skipping $output_path after failures."
  return 1
}

install_extension() {
  local repo_url=$1
  local repo_name=$(basename "$repo_url" .git)
  local target_dir="$FORGE_PATH/extensions/$repo_name"
  
  if [ ! -d "$target_dir" ]; then
    echo "Installing extension: $repo_name"
    git clone "$repo_url" "$target_dir" || echo "WARNING: Failed to clone $repo_name"
  else
    echo "Extension already installed: $repo_name"
  fi
}

# ====================================================================================
#  MAIN EXECUTION FLOW
# ====================================================================================

echo "Starting provisioning script..."

# 1. Forge Config & Extensions
download_file_with_retries "https://raw.githubusercontent.com/tamnhucanh/vast-provisioning-scripts/refs/heads/main/ui-config.json" "$FORGE_PATH/ui-config.json" || true

install_extension "https://github.com/Mikubill/sd-webui-controlnet.git" 
install_extension "https://github.com/camenduru/sd-webui-additional-networks.git" 
install_extension "https://github.com/AlUlkesh/stable-diffusion-webui-images-browser.git" 
install_extension "https://github.com/DominikDoom/a1111-sd-webui-tagcomplete.git" 
install_extension "https://github.com/adieyal/sd-dynamic-prompts.git" 
install_extension "https://github.com/Bing-su/adetailer.git" 
install_extension "https://github.com/BlafKing/sd-civitai-browser-plus.git" 

# 2. ControlNet Models
mkdir -p "$FORGE_PATH/extensions/sd-webui-controlnet/models"
download_file_with_retries "https://huggingface.co/lllyasviel/ControlNet-v1-1/resolve/main/control_v11p_sd15_canny.pth" "$FORGE_PATH/extensions/sd-webui-controlnet/models/control_v11p_sd15_canny.pth" || true
download_file_with_retries "https://huggingface.co/lllyasviel/ControlNet-v1-1/resolve/main/control_v11p_sd15_openpose.pth" "$FORGE_PATH/extensions/sd-webui-controlnet/models/control_v11p_sd15_openpose.pth" || true

# 3. VAE
mkdir -p "$FORGE_PATH/models/VAE"
download_file_with_retries "https://huggingface.co/stabilityai/sdxl-vae/resolve/main/sdxl_vae.safetensors" "$FORGE_PATH/models/VAE/sdxl_vae.safetensors" || true

# 4. Base Models
echo "=== Downloading Base Models ==="
ensure_civitai_asset_installed 1166878 "$MODEL_DIR" 

# 5. LoRAs
echo "=== Downloading LoRAs ==="
ensure_civitai_asset_installed 1074877 "$LORA_DIR" 
ensure_civitai_asset_installed 1486082 "$LORA_DIR" 
ensure_civitai_asset_installed 1360425 "$LORA_DIR" 
ensure_civitai_asset_installed 1470544 "$LORA_DIR" 
ensure_civitai_asset_installed 1674551 "$LORA_DIR" 
ensure_civitai_asset_installed 999582 "$LORA_DIR" 
ensure_civitai_asset_installed 1458421 "$LORA_DIR" 
ensure_civitai_asset_installed 960678 "$LORA_DIR" 

# --- SYMLINK FIX FOR EXTENSIONS & CONFIG ---
# This connects the /workspace extensions to the /app Forge instance
echo "--- Linking Extensions and Config to /app ---"
APP_DIR="/app/stable-diffusion-webui-forge"

# Remove default empty folders in /app if they exist
rm -rf "$APP_DIR/extensions"
rm -f "$APP_DIR/ui-config.json"

# Create symlinks pointing to /workspace
ln -s "$FORGE_PATH/extensions" "$APP_DIR/extensions"
ln -s "$FORGE_PATH/ui-config.json" "$APP_DIR/ui-config.json"

echo "Provisioning and Linking completed successfully!"
