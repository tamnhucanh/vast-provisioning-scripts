#!/bin/bash

# Set CivitAI API token from environment variable (set in Vast.ai template)
# Do NOT hardcode your token here; set it in the Vast.ai template as CIVITAI_TOKEN=your_actual_token
export CIVITAI_TOKEN="${CIVITAI_TOKEN}"

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

# Install your specified base models
cd /workspace/stable-diffusion-webui/models/Stable-diffusion

# Model 1: NTR MIX | illustrious-XL | Noob-XL (v1166878)
wget -nc "https://civitai.com/api/download/models/1166878?token=$CIVITAI_TOKEN" -O ntr_mix_xiii.safetensors

# Model 2: (v1612720)
wget -nc "https://civitai.com/api/download/models/1612720?token=$CIVITAI_TOKEN" -O model_827184.safetensors

# Model 3: (v1111838)
wget -nc "https://civitai.com/api/download/models/1111838?token=$CIVITAI_TOKEN" -O model_992378.safetensors

# Install LoRA models
cd /workspace/stable-diffusion-webui/models/Lora

# LoRA 1
wget -nc "https://civitai.com/api/download/models/1568786?token=$CIVITAI_TOKEN" -O lora_1033320_1568786.safetensors

# LoRA 2
wget -nc "https://civitai.com/api/download/models/1074877?token=$CIVITAI_TOKEN" -O lora_960071_1074877.safetensors

# LoRA 3
wget -nc "https://civitai.com/api/download/models/1486082?token=$CIVITAI_TOKEN" -O lora_1316436_1486082.safetensors

# LoRA 4
wget -nc "https://civitai.com/api/download/models/1360425?token=$CIVITAI_TOKEN" -O lora_1126830_1360425.safetensors

# LoRA 5
wget -nc "https://civitai.com/api/download/models/1470544?token=$CIVITAI_TOKEN" -O lora_1145743_1470544.safetensors

# LoRA 6
wget -nc "https://civitai.com/api/download/models/1645427?token=$CIVITAI_TOKEN" -O lora_971952_1645427.safetensors

# LoRA 7
wget -nc "https://civitai.com/api/download/models/999582?token=$CIVITAI_TOKEN" -O lora_893267_999582.safetensors

# LoRA 8
wget -nc "https://civitai.com/api/download/models/1364444?token=$CIVITAI_TOKEN" -O lora_1211374_1364444.safetensors

# LoRA 9
wget -nc "https://civitai.com/api/download/models/1458421?token=$CIVITAI_TOKEN" -O lora_1292332_1458421.safetensors

# (Optional) Install custom requirements
# /workspace/venv/bin/pip install <package-name>
