#!/bin/bash

# Set CivitAI API token from environment variable (set in Vast.ai template)
# NEVER hardcode your token here - set it via Vast.ai's environment variables
export CIVITAI_TOKEN="${CIVITAI_TOKEN}"

# Validate token presence early
if [ -z "$CIVITAI_TOKEN" ]; then
  echo "ERROR: CivitAI token not found! Set CIVITAI_TOKEN in Vast.ai template."
  exit 1
fi

# Base path for Forge
FORGE_PATH="/workspace/stable-diffusion-webui-forge"

# Install extensions with git clone robustness
install_extension() {
  repo_url=$1
  repo_name=$(basename "$repo_url" .git)
  if [ ! -d "$FORGE_PATH/extensions/$repo_name" ]; then
    git clone "$repo_url" "$FORGE_PATH/extensions/$repo_name" || echo "Warning: Failed to clone $repo_name"
  fi
}

# Original extensions
install_extension "https://github.com/Mikubill/sd-webui-controlnet.git"
install_extension "https://github.com/camenduru/sd-webui-additional-networks.git"
install_extension "https://github.com/AlUlkesh/stable-diffusion-webui-images-browser.git"

# Custom extensions
install_extension "https://github.com/DominikDoom/a1111-sd-webui-tagcomplete.git"
install_extension "https://github.com/adieyal/sd-dynamic-prompts.git"
install_extension "https://github.com/Bing-su/adetailer.git"
install_extension "https://github.com/BlafKing/sd-civitai-browser-plus.git"

# ControlNet models
mkdir -p "$FORGE_PATH/extensions/sd-webui-controlnet/models"
cd "$FORGE_PATH/extensions/sd-webui-controlnet/models"
wget -nc https://huggingface.co/lllyasviel/ControlNet-v1-1/resolve/main/control_v11p_sd15_canny.pth
wget -nc https://huggingface.co/lllyasviel/ControlNet-v1-1/resolve/main/control_v11p_sd15_openpose.pth

# VAE installation
mkdir -p "$FORGE_PATH/models/VAE"
cd "$FORGE_PATH/models/VAE"
wget -nc https://huggingface.co/stabilityai/sdxl-vae/resolve/main/sdxl_vae.safetensors

# Base models installation
mkdir -p "$FORGE_PATH/models/Stable-diffusion"
cd "$FORGE_PATH/models/Stable-diffusion"
download_model() {
  model_id=$1
  output_name=$2
  echo "Downloading model: $output_name"
  curl -H "Authorization: Bearer $CIVITAI_TOKEN" \
    -fL -o "$output_name" \
    "https://civitai.com/api/download/models/$model_id" || echo "Error downloading model $model_id"
}

download_model 1166878 "ntr_mix_xiii.safetensors"
download_model 1612720 "model_827184.safetensors"
download_model 1111838 "model_992378.safetensors"

# LoRA installation
mkdir -p "$FORGE_PATH/models/Lora"
cd "$FORGE_PATH/models/Lora"
download_lora() {
  model_id=$1
  output_name=$2
  echo "Downloading LoRA: $output_name"
  curl -H "Authorization: Bearer $CIVITAI_TOKEN" \
    -fL -o "$output_name" \
    "https://civitai.com/api/download/models/$model_id" || echo "Error downloading LoRA $model_id"
}

download_lora 1568786 "lora_1033320_1568786.safetensors"
download_lora 1074877 "lora_960071_1074877.safetensors"
download_lora 1486082 "lora_1316436_1486082.safetensors"
download_lora 1360425 "lora_1126830_1360425.safetensors"
download_lora 1470544 "lora_1145743_1470544.safetensors"
download_lora 1645427 "lora_971952_1645427.safetensors"
download_lora 999582 "lora_893267_999582.safetensors"
download_lora 1364444 "lora_1211374_1364444.safetensors"
download_lora 1458421 "lora_1292332_1458421.safetensors"

echo "Provisioning script completed with status: $?"
