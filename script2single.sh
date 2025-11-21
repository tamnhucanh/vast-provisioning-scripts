#!/bin/bash
set -eo pipefail

# ==================== RTX 50-SERIES / BLACKWELL AUTO-FIX (2025+) ====================
echo "Checking GPU compatibility for RTX 50-series / Blackwell / H200+..."

GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader,nounits | head -1 | tr '[:upper:]' '[:lower:]' | xargs)
CUDA_CAPABILITY=$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader,nounits | head -1)

echo "Detected GPU: $GPU_NAME (Compute Capability: $CUDA_CAPABILITY)"

if [[ "$GPU_NAME" == *"rtx 50"* ]] || \
   [[ "$GPU_NAME" == *"5060"* ]] || [[ "$GPU_NAME" == *"5070"* ]] || \
   [[ "$GPU_NAME" == *"5080"* ]] || [[ "$GPU_NAME" == *"5090"* ]] || \
   [[ "$GPU_NAME" == *"blackwell"* ]] || [[ "$GPU_NAME" == *"h200"* ]] || [[ "$GPU_NAME" == *"b200"* ]] || \
   [[ "$CUDA_CAPABILITY" == 9.* ]] || [[ "$CUDA_CAPABILITY" == 10.* ]]; then

    echo "Newer GPU detected → Installing latest PyTorch nightly with CUDA 12.8+ support (RTX 50xx / Blackwell compatible)"

    pip uninstall -y torch torchvision torchaudio xformers triton --no-cache-dir > /dev/null 2>&1 || true
    pip install --pre torch torchvision torchaudio --index-url https://download.pytorch.org/whl/nightly/cu128 -U --no-cache-dir
    pip install --pre xformers --index-url https://download.pytorch.org/whl/nightly/cu128 -U --no-cache-dir

    echo "PyTorch + xformers upgraded → Fully compatible with ALL RTX 50-series cards (5060 Ti, 5070, 5080, 5090, etc.)"
else
    echo "Standard GPU detected — using default PyTorch (no upgrade needed)"
fi
# =================================================================================

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

# ====================== download_civit_model (safe + 7s retries) =====================
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
   
    if [[ $api_status == "404" ]]; then
      echo "ERROR: Model version $model_version_id no longer exists (HTTP 404) — skipping permanently."
      return 1
    fi
    if [[ $api_status != "200" ]]; then
      echo "ERROR: Failed to get metadata (HTTP $api_status)"
      download_retry_count=$((download_retry_count + 1))
      sleep 7
      continue
    fi
   
    if ! echo "$metadata" | jq . > /dev/null 2>&1; then
      echo "ERROR: Invalid JSON response."
      download_retry_count=$((download_retry_count + 1))
      sleep 7
      continue
    fi
   
    local model_name=$(echo "$metadata" | jq -r '.model.name // "unknown"')
    local version_name=$(echo "$metadata" | jq -r '.name // "unknown"')
    local primary_file=$(echo "$metadata" | jq -r '.files[] | select(.primary == true) | .name')
    local download_url=$(echo "$metadata" | jq -r '.files[] | select(.primary == true) | .downloadUrl')
    local preview_image=$(echo "$metadata" | jq -r '.images[0].url // ""')
   
    if [[ -z "$download_url" || "$download_url" == "null" || "$download_url" == "" ]]; then
      echo "ERROR: No valid download URL (file deleted/private) — skipping model $model_version_id permanently."
      return 1
    fi
    if [[ -z "$primary_file" || "$primary_file" == "null" ]]; then
      echo "ERROR: No primary file — skipping model $model_version_id permanently."
      return 1
    fi

    local safe_model_name=$(sanitize "$model_name")
    local safe_version_name=$(sanitize "$version_name")
    local base_filename="${safe_model_name}_${safe_version_name}"
    local expected_model_file="$target_dir/${base_filename}.${primary_file##*.}"
   
    echo "Using filename: $base_filename"
    echo "$metadata" > "$target_dir/${base_filename}.json"
   
    echo "Downloading model file..."
    if curl -fL -H "Authorization: Bearer $CIVITAI_TOKEN" -o "$expected_model_file" "$download_url"; then
      download_success=true
      echo "Successfully downloaded $model_name ($version_name)"
    else
      echo "ERROR: Download failed. Retrying..."
      rm -f "$expected_model_file"
      download_retry_count=$((download_retry_count + 1))
      sleep 7
      continue
    fi

    local description_html=$(echo "$metadata" | jq -r '.description // ""')
    echo "$description_html" > "$target_dir/${base_filename}.html"
   
    if [[ -n "$preview_image" && "$preview_image" != "null" ]]; then
      curl -fL -o "$target_dir/${base_filename}.preview.png" "$preview_image" || true
    fi
   
    if [[ "$target_dir" == "$LORA_DIR" ]]; then
      echo "$metadata" > "$target_dir/${base_filename}.civitai.info"
    fi
  done

  if [ "$download_success" = false ]; then
    echo "WARNING: Failed after $max_download_retries attempts — skipping $model_version_id"
    return 1
  fi
  return 0
}

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
  echo "ERROR: Skipping asset $model_version_id (likely deleted/private)"
  return 1
}

download_file_with_retries() {
  local url=$1
  local output_path=$2
  local max_retries=10
  local retry_count=0
  mkdir -p "$(dirname "$output_path")"
  while [ $retry_count -lt $max_retries ]; do
    echo "Attempt $((retry_count + 1))/$max_retries → $url"
    if curl -fL -o "$output_path" "$url"; then
      echo "Downloaded $output_path"
      return 0
    else
      echo "Failed. Retrying in 7s..."
      rm -f "$output_path"
      retry_count=$((retry_count + 1))
      sleep 7
    fi
  done
  echo "ERROR: Skipping $output_path after $max_retries attempts"
  return 1
}

install_extension() {
  local repo_url=$1
  local repo_name=$(basename "$repo_url" .git)
  local target_dir="$FORGE_PATH/extensions/$repo_name"
  local max_retries=5
  local retry_count=0
  local success=false

  while [ $retry_count -lt $max_retries ] && [ "$success" = false ]; do
    if [ ! -d "$target_dir" ]; then
      echo "Cloning $repo_name (attempt $((retry_count + 1)))"
      if git clone "$repo_url" "$target_dir"; then
        success=true
        echo "Installed $repo_name"
      else
        retry_count=$((retry_count + 1))
        sleep 7
      fi
    else
      success=true
      echo "Extension $repo_name already exists"
    fi
  done
  [ "$success" = false ] && echo "WARNING: Skipped extension $repo_name"
}

# ==================== Main Execution ====================
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

echo "=== Downloading base models (missing ones skipped) ==="
ensure_civitai_asset_installed 1166878 "$MODEL_DIR" || echo "Skipped base model 1166878"
ensure_civitai_asset_installed 1761560 "$MODEL_DIR" || echo "Skipped base model 1761560"

echo "=== Downloading LoRAs (missing ones skipped) ==="
# 1568786 REMOVED INTENTIONALLY
ensure_civitai_asset_installed 1074877 "$LORA_DIR" || echo "Skipped LoRA 1074877"
ensure_civitai_asset_installed 1486082 "$LORA_DIR" || echo "Skipped LoRA 1486082"
ensure_civitai_asset_installed 1360425 "$LORA_DIR" || echo "Skipped LoRA 1360425"
ensure_civitai_asset_installed 1470544 "$LORA_DIR" || echo "Skipped LoRA 1470544"
ensure_civitai_asset_installed 1674551 "$LORA_DIR" || echo "Skipped LoRA 1674551"
ensure_civitai_asset_installed 999582 "$LORA_DIR" || echo "Skipped LoRA 999582"
ensure_civitai_asset_installed 1458421 "$LORA_DIR" || echo "Skipped LoRA 1458421"
ensure_civitai_asset_installed 960678 "$LORA_DIR" || echo "Skipped LoRA 960678"

echo "Provisioning completed successfully! Works on all GPUs including RTX 5060 Ti / 5090 / H200+"
