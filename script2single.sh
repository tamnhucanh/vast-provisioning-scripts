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

# ===================== NEW: Smarter download with 404 detection =====================
download_file_with_retries() {
  local url=$1
  local output_path=$2
  local max_retries=5
  local retry_count=0
  local http_code=0

  mkdir -p "$(dirname "$output_path")"

  while [ $retry_count -lt $max_retries ]; do
    echo "Attempt $((retry_count + 1))/$max_retries to download $url → $output_path"
    
    # Capture HTTP status code
    http_code=$(curl -fL -o "$output_path" --write-out "%{http_code}" "$url" || echo "000")
    
    if [[ $http_code == "200" ]]; then
      echo "Successfully downloaded $output_path"
      return 0
    elif [[ $http_code == "404" ]]; then
      echo "ERROR: Permanent 404 for $url – skipping this file after $((retry_count + 1)) attempts."
      rm -f "$output_path"  # clean partial file if any
      return 1  # Caller will treat as skippable
    else
      echo "WARNING: Download failed (HTTP $http_code). Retrying in 15 seconds..."
      rm -f "$output_path"
      retry_count=$((retry_count + 1))
      sleep 15
    fi
  done

  echo "ERROR: Failed to download $url after $max_retries attempts (last HTTP: $http_code) – skipping."
  rm -f "$output_path"
  return 1  # Skippable failure
}

# ===================== Modified download_civit_model to be non-fatal on 404 =====================
download_civit_model() {
  local model_version_id=$1
  local target_dir=$2
  local max_download_retries=5
  local download_retry_count=0
  local download_success=false

  mkdir -p "$target_dir" || { echo "ERROR: Failed to create directory $target_dir"; return 1; }
  
  while [ $download_retry_count -lt $max_download_retries ] && [ "$download_success" = false ]; do
    echo "Attempt $((download_retry_count + 1))/$max_download_retries for model version $model_version_id..."

    local api_response
    local api_status
    api_response=$(curl -s -w "%{http_code}" -H "Authorization: Bearer $CIVITAI_TOKEN" \
      "https://civitai.com/api/v1/model-versions/$model_version_id")
    
    api_status=${api_response: -3}
    local metadata=${api_response:0:${#api_response}-3}
    
    if [[ $api_status != "200" ]]; then
      if [[ $api_status == "404" ]]; then
        echo "ERROR: Model version $model_version_id returns 404 from CivitAI API – skipping this model entirely."
        return 1  # Skip this model
      fi
      echo "ERROR: Failed to get metadata (HTTP $api_status). Retrying..."
      download_retry_count=$((download_retry_count + 1))
      sleep 15
      continue
    fi

    # ... [rest of metadata parsing unchanged until download section] ...

    # Download model file – now using the smarter function that detects 404
    echo "Downloading primary model file..."
    if download_file_with_retries "$download_url" "$expected_model_file"; then
      download_success=true
    else
      # If it was a 404, we skip this whole model
      if grep -q "Permanent 404" <(echo "$output"); then
        echo "Model file permanently missing (404) – skipping entire model $model_version_id"
        rm -f "$target_dir/${base_filename}".*
        return 1
      fi
      download_retry_count=$((download_retry_count + 1))
      sleep 30
      continue
    fi

    # ... [preview image, description, etc. – unchanged] ...
  done

  if [ "$download_success" = false ]; then
    echo "WARNING: Could not download model $model_version_id after retries – skipping it."
    return 1  # Non-fatal
  fi

  echo "Successfully processed model $model_version_id: $model_name ($version_name)"
  return 0
}

# ===================== ensure_civitai_asset_installed – now continues on failure =====================
ensure_civitai_asset_installed() {
  local model_version_id=$1
  local target_dir=$2
  local max_installation_retries=3
  local installation_retry_count=0

  while [ $installation_retry_count -lt $max_installation_retries ]; do
    echo "--- Ensuring CivitAI asset $model_version_id (Attempt $((installation_retry_count + 1))/$max_installation_retries) ---"
    
    if download_civit_model "$model_version_id" "$target_dir"; then
      echo "CivitAI asset $model_version_id installed successfully."
      return 0
    else
      echo "WARNING: Failed attempt for asset $model_version_id. Will retry entire process..."
      installation_retry_count=$((installation_retry_count + 1))
      sleep 60
    fi
  done

  # After all full retries → skip instead of exit
  echo "ERROR: Permanently failed to install CivitAI asset $model_version_id (possibly deleted/404). Continuing without it."
  return 1  # Non-fatal
}

# ===================== Extension install – also made non-fatal =====================
install_extension() {
  local repo_url=$1
  local repo_name=$(basename "$repo_url" .git)
  local target_dir="$FORGE_PATH/extensions/$repo_name"
  local max_retries=5
  local retry_count=0

  while [ $retry_count -lt $max_retries ]; do
    if [ ! -d "$target_dir" ]; then
      echo "Cloning extension $repo_name (attempt $((retry_count + 1)))"
      if git clone "$repo_url" "$target_dir"; then
        echo "Extension $repo_name installed."
        return 0
      else
        retry_count=$((retry_count + 1))
        sleep 10
      fi
    else
      echo "Extension $repo_name already present."
      return 0
    fi
  done

  echo "WARNING: Failed to install extension $repo_name after $max_retries attempts – continuing without it."
  return 1  # Non-fatal now
}

# ===================== Main Execution – no more exit on single failure =====================

echo "Starting provisioning script..."

# These are now non-fatal too
download_file_with_retries "https://raw.githubusercontent.com/tamnhucanh/vast-provisioning-scripts/refs/heads/main/ui-config.json" "$FORGE_PATH/ui-config.json" || echo "ui-config.json missing – continuing"

install_extension "https://github.com/Mikubill/sd-webui-controlnet.git" || true
install_extension "https://github.com/camenduru/sd-webui-additional-networks.git" || true
install_extension "https://github.com/AlUlkesh/stable-diffusion-webui-images-browser.git" || true
install_extension "https://github.com/DominikDoom/a1111-sd-webui-tagcomplete.git" || true
install_extension "https://github.com/adieyal/sd-dynamic-prompts.git" || true
install_extension "https://github.com/Bing-su/adetailer.git" || true
install_extension "https://github.com/BlafKing/sd-civitai-browser-plus.git" || true

# ControlNet & VAE models – skip on permanent failure
download_file_with_retries "https://huggingface.co/lllyasviel/ControlNet-v1-1/resolve/main/control_v11p_sd15_canny.pth" "$FORGE_PATH/extensions/sd-webui-controlnet/models/control_v11p_sd15_canny.pth" || echo "Skipped canny ControlNet"
download_file_with_retries "https://huggingface.co/lllyasviel/ControlNet-v1-1/resolve/main/control_v11p_sd15_openpose.pth" "$FORGE_PATH/extensions/sd-webui-controlnet/models/control_v11p_sd15_openpose.pth" || echo "Skipped openpose ControlNet"
download_file_with_retries "https://huggingface.co/stabilityai/sdxl-vae/resolve/main/sdxl_vae.safetensors" "$FORGE_PATH/models/VAE/sdxl_vae.safetensors" || echo "Skipped VAE"

# Models & LoRAs – will skip any that 404 or are deleted
echo "=== Downloading base models (will skip missing ones) ==="
ensure_civitai_asset_installed 1166878 "$MODEL_DIR" || echo "Skipped base model 1166878"
ensure_civitai_asset_installed 1761560 "$MODEL_DIR" || echo "Skipped base model 1761560"

echo "=== Downloading LoRAs (will skip missing ones) ==="
ensure_civitai_asset_installed 1568786 "$LORA_DIR" || echo "Skipped LoRA 1568786"
ensure_civitai_asset_installed 1074877 "$LORA_DIR" || echo "Skipped LoRA 1074877"
ensure_civitai_asset_installed 1486082 "$LORA_DIR" || echo "Skipped LoRA 1486082"
ensure_civitai_asset_installed 1360425 "$LORA_DIR" || echo "Skipped LoRA 1360425"
ensure_civitai_asset_installed 1470544 "$LORA_DIR" || echo "Skipped LoRA 1470544"
ensure_civitai_asset_installed 1674551 "$LORA_DIR" || echo "Skipped LoRA 1674551"
ensure_civitai_asset_installed 999582 "$LORA_DIR" || echo "Skipped LoRA 999582"
ensure_civitai_asset_installed 1458421 "$LORA_DIR" || echo "Skipped LoRA 1458421"
ensure_civitai_asset_installed 960678 "$LORA_DIR" || echo "Skipped LoRA 960678"

echo "Provisioning completed! Some files may have been skipped if they are no longer available (404), but the instance will still start."
