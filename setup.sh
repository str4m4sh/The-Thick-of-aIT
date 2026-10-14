#!/usr/bin/env bash
# ==============================================================================
# AI Agent Server - Automated Ubuntu Setup Script
# Configured for: 4-Core CPU, 8GB RAM, 256GB SSD (Ubuntu 20.04/22.04/24.04)
# ==============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

if [ "$EUID" -ne 0 ]; then
  log_error "Please run this script with sudo: sudo bash $0"
  exit 1
fi

CURRENT_USER="${SUDO_USER:-$USER}"
USER_HOME=$(eval echo "~$CURRENT_USER")
APP_DIR="${USER_HOME}/ai-agent-server"

echo -e "${BLUE}"
echo "=========================================================="
echo "      Deploying 5-Agent AI Server (Ubuntu Edition)       "
echo "=========================================================="
echo -e "${NC}"

# ------------------------------------------------------------------------------
# 1. SWAP CONFIGURATION (Essential for 8GB RAM)
# ------------------------------------------------------------------------------
SWAP_EXISTS=$(swapon --show | wc -l)
if [ "$SWAP_EXISTS" -le 1 ]; then
    log_info "Configuring 8GB swap space to guard against out-of-memory spikes..."
    fallocate -l 8G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=8192
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    if ! grep -q '/swapfile' /etc/fstab; then
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
    fi
    log_success "8GB swap created and enabled."
else
    log_info "Swap is already active. Skipping swap creation."
fi

# ------------------------------------------------------------------------------
# 2. SYSTEM PACKAGES & DOCKER
# ------------------------------------------------------------------------------
log_info "Updating system packages and installing prerequisites..."
apt-get update -y
apt-get install -y --no-install-recommends \
    curl \
    wget \
    git \
    jq \
    python3 \
    python3-venv \
    python3-pip \
    docker.io

log_info "Enabling Docker service..."
systemctl enable --now docker
usermod -aG docker "$CURRENT_USER" || true

log_info "Pre-caching Python sandbox image in Docker..."
docker pull python:3.11-slim
log_success "Docker configured and sandbox image ready."

# ------------------------------------------------------------------------------
# 3. OLLAMA INSTALLATION & LIGHTWEIGHT MODELS
# ------------------------------------------------------------------------------
if ! command -v ollama &> /dev/null; then
    log_info "Installing Ollama inference engine..."
    curl -fsSL https://ollama.com/install.sh | sh
    systemctl enable --now ollama
    sleep 3
else
    log_info "Ollama already installed."
fi

log_info "Waiting for Ollama service to respond..."
until curl -s http://127.0.0.1:11434/api/tags > /dev/null; do
    sleep 2
done

log_info "Downloading CPU-friendly, low-RAM models (this may take a few minutes)..."
# Pull Qwen 2.5 Coder (best small code model) and Llama 3.2 (conversations)
ollama pull qwen2.5-coder:3b
ollama pull llama3.2:3b
log_success "AI models pulled successfully."

# ------------------------------------------------------------------------------
# 4. DEPLOY SERVER FILES
# ------------------------------------------------------------------------------
log_info "Setting up project directory at: $APP_DIR"
mkdir -p "$APP_DIR"
cd "$APP_DIR"

cat << 'EOF' > requirements.txt
fastapi>=0.110.0
uvicorn>=0.28.0
pydantic>=2.6.0
httpx>=0.27.0
python-dotenv>=1.0.1
EOF

cat << 'EOF' > sandbox.py
import os
import subprocess
import tempfile
from typing import Dict, Any

def run_in_sandbox(code: str, language: str = "python", timeout: int = 15) -> Dict[str, Any]:
    if language.lower() not in ["python", "py"]:
        return {
            "success": False,
            "stdout": "",
            "stderr": f"Language '{language}' not supported. Only Python is enabled.",
            "returncode": -1
        }

    with tempfile.NamedTemporaryFile(mode="w", suffix=".py", delete=False, encoding="utf-8") as tmp:
        tmp.write(code)
        tmp_path = tmp.name

    try:
        container_mount = f"{os.path.abspath(tmp_path)}:/app/script.py:ro"
        cmd = [
            "docker", "run", "--rm",
            "--network", "none",
            "--memory", "512m",
            "--cpus", "1.0",
            "-v", container_mount,
            "python:3.11-slim",
            "python3", "/app/script.py"
        ]

        result = subprocess.run(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=timeout
        )

        return {
            "success": result.returncode == 0,
            "stdout": result.stdout.strip(),
            "stderr": result.stderr.strip(),
            "returncode": result.returncode
        }
    except subprocess.TimeoutExpired:
        return {
            "success": False,
            "stdout": "",
            "stderr": f"Execution timed out after {timeout} seconds.",
            "returncode": -1
        }
    except Exception as e:
        return {
            "success": False,
            "stdout": "",
            "stderr": f"Sandbox runner error: {str(e)}",
            "returncode": -1
        }
    finally:
        if os.path.exists(tmp_path):
            os.remove(tmp_path)
EOF

cat << 'EOF' > agents.py
import os
import re
import json
import httpx
from typing import Dict, Any, List, Optional
from sandbox import run_in_sandbox

LLM_BASE_URL = os.getenv("LLM_BASE_URL", "http://localhost:11434/v1")
LLM_API_KEY = os.getenv("LLM_API_KEY", "ollama")
CHAT_MODEL = os.getenv("CHAT_MODEL", "llama3.2:3b")
CODE_MODEL = os.getenv("CODE_MODEL", "qwen2.5-coder:3b")

async def call_llm(messages: List[Dict[str, str]], model: str, temperature: float = 0.3) -> str:
    headers = {
        "Authorization": f"Bearer {LLM_API_KEY}",
        "Content-Type": "application/json"
    }
    payload = {
        "model": model,
        "messages": messages,
        "temperature": temperature,
        "stream": False
    }

    async with httpx.AsyncClient(timeout=60.0) as client:
        response = await client.post(f"{LLM_BASE_URL.rstrip('/')}/chat/completions", headers=headers, json=payload)
        response.raise_for_status()
        data = response.json()
        return data["choices"][0]["message"]["content"]

def extract_python_code(text: str) -> str:
    match = re.search(r"```python\s*(.*?)\s*```", text, re.DOTALL | re.IGNORECASE)
    if match:
        return match.group(1).strip()
    match = re.search(r"```\s*(.*?)\s*```", text, re.DOTALL)
    if match:
        return match.group(1).strip()
    return text.strip()

class AgentTeam:
    def __init__(self):
        self.chat_model = CHAT_MODEL
        self.code_model = CODE_MODEL

    async def route(self, user_prompt: str) -> str:
        prompt = (
            "You are an AI Router. Categorize the user request into either 'chat' or 'code'.\n"
            "- 'code': The user wants code written, debugged, tested, or executed.\n"
            "- 'chat': General conversation, greetings, questions, or conceptual explanation.\n"
            "Respond ONLY with one word: 'chat' or 'code'."
        )
        messages = [
            {"role": "system", "content": prompt},
            {"role": "user", "content": user_prompt}
        ]
        decision = await call_llm(messages, model=self.chat_model, temperature=0.0)
        return "code" if "code" in decision.lower() else "chat"

    async def conversation(self, user_prompt: str, history: Optional[List[Dict[str, str]]] = None) -> str:
        messages = [
            {"role": "system", "content": "You are a helpful, friendly, and knowledgeable AI assistant."}
        ]
        if history:
            messages.extend(history)
        messages.append({"role": "user", "content": user_prompt})
        return await call_llm(messages, model=self.chat_model, temperature=0.7)

    async def plan(self, task_description: str) -> str:
        messages = [
            {
                "role": "system",
                "content": "You are a Software Architect. Break down the user coding request into a concise implementation plan."
            },
            {"role": "user", "content": task_description}
        ]
        return await call_llm(messages, model=self.code_model, temperature=0.2)

    async def develop(self, task_description: str, plan: str, feedback: Optional[str] = None) -> str:
        system_content = (
            "You are a Senior Python Developer. Write clean, complete, robust Python code.\n"
            "Wrap your code inside ```python ``` blocks."
        )
        user_content = f"Requirement: {task_description}\n\nPlan:\n{plan}"
        if feedback:
            user_content += f"\n\nPrevious attempt failed with error:\n{feedback}\nPlease fix the code."

        messages = [
            {"role": "system", "content": system_content},
            {"role": "user", "content": user_content}
        ]
        response = await call_llm(messages, model=self.code_model, temperature=0.2)
        return extract_python_code(response)

    async def review_and_test(self, code: str) -> Dict[str, Any]:
        sandbox_result = run_in_sandbox(code, language="python")
        review_prompt = (
            "You are a QA Reviewer. Give a 2-sentence summary of this code and its execution results:\n"
            f"Code:\n```python\n{code}\n```\n"
            f"Success: {sandbox_result['success']}\n"
            f"STDOUT: {sandbox_result['stdout']}\n"
            f"STDERR: {sandbox_result['stderr']}"
        )
        messages = [{"role": "system", "content": review_prompt}]
        analysis = await call_llm(messages, model=self.code_model, temperature=0.1)
        return {
            "sandbox": sandbox_result,
            "review": analysis
        }

    async def run_pipeline(self, user_prompt: str) -> Dict[str, Any]:
        route = await self.route(user_prompt)
        if route == "chat":
            reply = await self.conversation(user_prompt)
            return {
                "route": "chat",
                "agent_chain": ["Router", "Conversationalist"],
                "response": reply
            }

        plan = await self.plan(user_prompt)
        code = await self.develop(user_prompt, plan)
        test_review = await self.review_and_test(code)

        if not test_review["sandbox"]["success"]:
            feedback = f"Error: {test_review['sandbox']['stderr']}"
            code = await self.develop(user_prompt, plan, feedback=feedback)
            test_review = await self.review_and_test(code)

        return {
            "route": "code",
            "agent_chain": ["Router", "Architect", "Developer", "Reviewer/Tester"],
            "plan": plan,
            "code": code,
            "execution": test_review["sandbox"],
            "review": test_review["review"]
        }
EOF

cat << 'EOF' > server.py
import os
import uvicorn
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, Field
from typing import Optional, List, Dict, Any
from agents import AgentTeam
from dotenv import load_dotenv

load_dotenv()

app = FastAPI(
    title="AI Agent Server",
    description="5-Agent Orchestrator for Conversational Chat and Sandboxed Code Execution",
    version="1.0.0"
)

team = AgentTeam()

class PromptRequest(BaseModel):
    prompt: str = Field(..., example="Write a python function to compute fibonacci numbers and test it")

class ChatRequest(BaseModel):
    prompt: str = Field(..., example="Explain how Docker namespaces work in simple terms")
    history: Optional[List[Dict[str, str]]] = Field(default=None)

@app.get("/health")
async def health_check():
    return {
        "status": "healthy",
        "chat_model": team.chat_model,
        "code_model": team.code_model
    }

@app.post("/v1/process")
async def process_request(request: PromptRequest):
    try:
        return await team.run_pipeline(request.prompt)
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

@app.post("/v1/chat")
async def chat_endpoint(request: ChatRequest):
    try:
        reply = await team.conversation(request.prompt, request.history)
        return {"agent": "Conversationalist", "response": reply}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

@app.post("/v1/code")
async def code_endpoint(request: PromptRequest):
    try:
        plan = await team.plan(request.prompt)
        code = await team.develop(request.prompt, plan)
        test_review = await team.review_and_test(code)

        if not test_review["sandbox"]["success"]:
            feedback = f"Error: {test_review['sandbox']['stderr']}"
            code = await team.develop(request.prompt, plan, feedback=feedback)
            test_review = await team.review_and_test(code)

        return {
            "plan": plan,
            "code": code,
            "execution": test_review["sandbox"],
            "review": test_review["review"]
        }
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

if __name__ == "__main__":
    host = os.getenv("HOST", "0.0.0.0")
    port = int(os.getenv("PORT", 8000))
    uvicorn.run("server:app", host=host, port=port, reload=False)
EOF

if [ ! -f .env ]; then
    cat << 'EOF' > .env
HOST=0.0.0.0
PORT=8000
LLM_BASE_URL=http://localhost:11434/v1
LLM_API_KEY=ollama
CHAT_MODEL=llama3.2:3b
CODE_MODEL=qwen2.5-coder:3b
EOF
fi

# ------------------------------------------------------------------------------
# 5. PYTHON VIRTUAL ENVIRONMENT & DEPENDENCIES
# ------------------------------------------------------------------------------
log_info "Creating Python virtual environment..."
python3 -m venv venv
./venv/bin/pip install --upgrade pip
./venv/bin/pip install -r requirements.txt
log_success "Python dependencies installed."

# ------------------------------------------------------------------------------
# 6. SYSTEMD SERVICE CONFIGURATION
# ------------------------------------------------------------------------------
log_info "Registering ai-agents systemd service..."

cat << EOF > /etc/systemd/system/ai-agents.service
[Unit]
Description=5-Agent AI Server Daemon
After=network.target docker.service ollama.service
Requires=docker.service ollama.service

[Service]
Type=simple
User=$CURRENT_USER
WorkingDirectory=$APP_DIR
ExecStart=$APP_DIR/venv/bin/python3 $APP_DIR/server.py
Restart=always
RestartSec=5
EnvironmentFile=-$APP_DIR/.env

[Install]
WantedBy=multi-user.target
EOF

chown -R "$CURRENT_USER":"$CURRENT_USER" "$APP_DIR"
systemctl daemon-reload
systemctl enable --now ai-agents.service

# ------------------------------------------------------------------------------
# 7. HEALTHCHECK VERIFICATION
# ------------------------------------------------------------------------------
log_info "Verifying server status..."
sleep 4

SERVER_IP=$(hostname -I | awk '{print $1}')

if curl -s http://127.0.0.1:8000/health > /dev/null; then
    log_success "AI Agent Server is up and running!"
    echo ""
    echo -e "${GREEN}==========================================================${NC}"
    echo -e "${GREEN}                 DEPLOYMENT COMPLETE                      ${NC}"
    echo -e "${GREEN}==========================================================${NC}"
    echo -e "Web API URL:     http://${SERVER_IP}:8000"
    echo -e "API Swagger Doc: http://${SERVER_IP}:8000/docs"
    echo -e "Project Path:    ${APP_DIR}"
    echo ""
    echo -e "${YELLOW}Quick Test (Unified 5-Agent Pipeline):${NC}"
    echo "curl -X POST http://127.0.0.1:8000/v1/process \\"
    echo "  -H 'Content-Type: application/json' \\"
    echo "  -d '{\"prompt\": \"Write a python script that calculates prime numbers up to 50 and print them\"}'"
    echo ""
    echo -e "${YELLOW}Manage the service:${NC}"
    echo "  sudo systemctl status ai-agents"
    echo "  sudo journalctl -u ai-agents -f"
    echo ""
else
    log_warn "Service started, but healthcheck didn't respond immediately. Check logs with:"
    echo "  sudo journalctl -u ai-agents -n 50 --no-pager"
fi
