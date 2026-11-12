# Deepseek-Harness
ϛѨЯVIN™ Ai core deepseek harness android agent luncher 

## Install (Termux / Android / Linux)

One command — detects your environment, installs everything needed (proot Debian + Node 24), starts the DeepSeek Harness web UI and opens it in your browser:

```sh
curl -fsSL https://raw.githubusercontent.com/aishervin/Deepseek-Harness/main/dsh-setup.sh | bash
```

Diagnostics only:

```sh
curl -fsSL https://raw.githubusercontent.com/aishervin/Deepseek-Harness/main/dsh-setup.sh | bash -s -- --check
```

Options: `DSH_DISTRO=ubuntu` to use Ubuntu instead of Debian, `DEEPSEEK_API_KEY` to chat.

> ⚠️ DeepSeek Harness is experimental software that executes model-generated code. Use with least privileges.
