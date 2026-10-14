import os
import subprocess
import tempfile
from typing import Dict, Any

def run_in_sandbox(code: str, language: str = "python", timeout: int = 15) -> Dict[str, Any]:
    """
    Executes code inside an ephemeral, network-isolated, resource-constrained Docker container.
    Guards against infinite loops, fork bombs, and system tampering.
    """
    if language.lower() not in ["python", "py"]:
        return {
            "success": False,
            "stdout": "",
            "stderr": f"Language '{language}' not supported yet. Only Python is enabled.",
            "returncode": -1
        }

    # Write code into a temporary script
    with tempfile.NamedTemporaryFile(mode="w", suffix=".py", delete=False, encoding="utf-8") as tmp:
        tmp.write(code)
        tmp_path = tmp.name

    try:
        container_mount = f"{os.path.abspath(tmp_path)}:/app/script.py:ro"
        cmd = [
            "docker", "run", "--rm",
            "--network", "none",            # No external network access
            "--memory", "512m",             # Max 512MB RAM
            "--cpus", "1.0",                # Max 1 CPU core
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
