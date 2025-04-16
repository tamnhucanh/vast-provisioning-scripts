#!/bin/bash

# Set CivitAI API token from environment variable (set in Vast.ai template)
export CIVITAI_TOKEN="{YOUR_CIVITAI_TOKEN}"  # Replace with your actual token

# Install extensions (original + your custom)
cd /workspace/stable-diffusion-webui/extensions

# Original extensions
git clone https://github.com/Mikubill/sd-webui-controlnet.git || true
git clone https://github.com/camenduru/sd-webui-additional-networks.git || true
git clone https://github.com/AlUlkesh/stable-diffusion-webui-images-browser.git || true

# Your custom extensions
git clone https://github.com/DominikDoom/a1111-sd-webui-tagcomplete.git || true
git clone https://github.com/adieyal/sd-dynamic-prompts.git || true
git clone https://github.com/Bing-su/adetailer.git || true
git clone https://github.com/BlafKing/sd-civitai-browser-plus.git || true

# Install ControlNet models (from original script)
cd /workspace/stable-diffusion-webui/extensions/sd-webui-controlnet/models
wget -nc https://huggingface.co/lllyasviel/ControlNet-v1-1/resolve/main/control_v11p_sd15_canny.pth
wget -nc https://huggingface.co/lllyasviel/ControlNet-v1-1/resolve/main/control_v11p_sd15_openpose.pth

# Install VAE (from original script)
cd /workspace/stable-diffusion-webui/models/VAE
wget -nc https://huggingface.co/stabilityai/sdxl-vae/resolve/main/sdxl_vae.safetensors

# Install your specified models
cd /workspace/stable-diffusion-webui/models/Stable-diffusion

# Model 1: NTR MIX | illustrious-XL | Noob-XL (v1166878)
wget -nc "https://civitai.com/api/download/models/1166878?token=$CIVITAI_TOKEN" -O ntr_mix_xiii.safetensors

# Model 2: [Original Model Name] (v1612720)
wget -nc "https://civitai.com/api/download/models/1612720?token=$CIVITAI_TOKEN" -O model_827184.safetensors

# Model 3: [Original Model Name] (v1111838)
wget -nc "https://civitai.com/api/download/models/1111838?token=$CIVITAI_TOKEN" -O model_992378.safetensors

# (Optional) Install LoRA/embeddings - uncomment and modify as needed
# cd /workspace/stable-diffusion-webui/models/Lora
# wget -nc "https://civitai.com/api/download/models/...?token=$CIVITAI_TOKEN"

# (Optional) Install custom requirements
# /workspace/venv/bin/pip install <package-name>
