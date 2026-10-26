# CPA + OMC + GitStore + Caddy — one prebuilt image, Hugging Face Docker Space

这是 **源码打包 + GitHub Actions 自动发布方案**，不是已经推送到某个账号的镜像。未连接你的 GitHub 账号之前，不可能凭空生成有效的 `ghcr.io/<你的用户名>/<仓库名>:latest` 地址。

## 文件说明

- `Dockerfile`：在 GitHub Actions 中将 CPA、OMC、Caddy 合为一个运行时镜像。
- `start.sh`：初始化 CPA GitStore、设置 OMC 环境和三个进程的 Go 内存软目标、内存日志。
- `Caddyfile`：公网只开放 `7860`，其中 OMC 走 `/omc/`，推理 API 走 `/v1*`。
- `.github/workflows/publish-ghcr.yml`：推送到 `main` 或手动运行时构建、发布 GHCR 镜像。
- `hf-space/Dockerfile` + `hf-space/README.md`：复制到 HF Space 根目录即可部署预构建镜像。

## 第 1 步：发布 GHCR 镜像

1. 在 GitHub 上新建一个 **镜像构建仓库**，例如 `YOUR_USERNAME/cpa-omc-hf`。它与 CPA 的 **私有 GitStore 数据仓库**是两个不同的仓库。
2. 把此包的 **根目录文件（含 `.github/workflows/`）** 上传到镜像构建仓库，分支命名为 `main`。**不要上传 `hf-space/` 内容到镜像仓库根目录**，它们保留在子目录即可。
3. 打开 GitHub → **Actions** → `Build and publish GHCR image`；首次上传到 `main` 会触发，也可以点击 `Run workflow`。
4. 工作流成功后，在 GitHub 的 **Packages** 找到镜像，将 package **Visibility 改为 Public**。私有仓库的镜像可能默认私有；HF 无法匿名 `FROM` 私有 GHCR 镜像。
5. 镜像名通常是：`ghcr.io/your_username/cpa-omc-hf:latest`（工作流会自动转为小写）。可从该 Package 页面复制实际拉取地址，不要凭猜测替换。

此流程在 GitHub Actions 中使用临时 `GITHUB_TOKEN` 和 `packages: write` 发布，不需要把你的 GitHub PAT 放进 **镜像构建仓库**。如果组织策略禁止 Actions 发布软件包，需要管理员允许。

**注意**：每次更新构建仓库的 `main` 都可能覆盖 `latest`。建议在跑通后创建 `v1.0.0` 这样的 Tag，在 HF 的 `FROM` 中使用 `:v1.0.0`，或者使用镜像 digest `@sha256:...` 锁定版本。上游 CPA/OMC 当前使用 `latest`，重建时可能带入新版本；生产环境应替换为已验证的 digest。

## 第 2 步：部署 HF Space

1. 必须已有**有权限运行的 Docker Space**。HF 现在规定新建 Docker Space 需要 PRO/Team/Enterprise 等符合条件的计划，CPU Basic 虽然按小时免费，但免费个人计划通常不能新建。**预构建镜像不能绕过 HF 的账户限制。**
2. 打开 `hf-space/Dockerfile`，把 `YOUR_USERNAME/YOUR_IMAGE_REPO` 替换为上一步 Packages 中实际发布的名字。
3. 将 **`hf-space` 目录内的两个文件**（`Dockerfile` 和 `README.md`）上传至 **Space 仓库根目录**。HF 构建此极简 Dockerfile 时只拉取 GHCR 镜像，不再编译/复制 CPA 和 OMC。
4. 在 Space **Settings → Variables and secrets → Secrets** 中设置下表中的 5 个必填项（GitHub 用户名可选）。

| Secret | 填写内容 |
| --- | --- |
| `GITSTORE_GIT_URL` | `https://github.com/YOUR_USERNAME/cpa-private-data.git`（**另一个私有数据仓库**） |
| `GITSTORE_GIT_TOKEN` | 仅对数据仓库具有 **Contents: Read and write** 的 fine-grained PAT |
| `CPA_MANAGEMENT_KEY` | 任意非空、建议 16+ 位强密码；**没有 64 位 hex 的限制** |
| `CPA_API_KEY` | 初次初始化时写入 CPA 的模型调用 API Key；建议 `openssl rand -hex 32`，但不强制 64 位 |
| `OMCPA_MASTER_KEY` | **必须**使用 `openssl rand -hex 32` 生成的 64 位 hex 加密密钥，不要随意轮换 |
| `GITSTORE_GIT_USERNAME` | **可选**，GitHub 登录用户名；省略时使用 HTTPS 用户名 `x-access-token` |

注意：`GITSTORE_GIT_URL` 指向的是 **CPA 数据仓库**，绝对不是镜像构建仓库，也不是 HF Space 仓库。私有数据仓库里的 `config/config.yaml` 和 `auths/` 都可能包含真实密钥与 OAuth Token。

在 **Variables** 中还可添加下列可选项（代码已提供默认值）：

| Variable | Default |
| --- | --- |
| `CPA_GOMEMLIMIT` | `3GiB` |
| `OMC_GOMEMLIMIT` | `2GiB` |
| `CADDY_GOMEMLIMIT` | `512MiB` |
| `GO_GC_PERCENT` | `80` |

这些是 Go 软内存目标，不是内核硬性限制；不能保证不会 OOM。脚本每 5 分钟在 HF Logs 打印 cgroup 内存占用。

## 第 3 步：验证运行

- `https://YOUR_SPACE.hf.space/omc/`：OMC 管理页面，以 `CPA_MANAGEMENT_KEY` 登录。
- `https://YOUR_SPACE.hf.space/healthz`：Caddy 自身存活探针，只保证反向代理存活，**不是** CPA/OMC 健康证明。
- `https://YOUR_SPACE.hf.space/v1/models`：使用 `Authorization: Bearer <当前 CPA API Key>` 访问。
- 打开 GitHub **私有数据仓库**，确认 CPA 成功生成 `config/config.yaml`。凭证的自动 Git 同步需要查看日志并实际确认 commit，不要仅因页面能打开就视为备份成功。

```bash
curl -fsS -H 'Authorization: Bearer YOUR_CPA_API_KEY' \
  'https://YOUR_SPACE.hf.space/v1/models'
```

## 限制与安全提醒

- **OMC 数据库不持久化**：GitStore 只保存 CPA 的配置和认证文件；HF 临时磁盘重置可能丢失 OMC SQLite 统计记录、设置及历史。要长期保留 OMC 统计，应另做 SQLite 安全备份。
- **GitHub PAT 是数据仓库凭证**：只放 HF Secrets，千万不要写进 Dockerfile、镜像源仓库、README、HF Variables 或镜像层。
- **GitStore 单写者**：不要让多个 CPA 实例共用同一 GitStore 仓库并同时写入，防止 Git 冲突。
- **首次配置和后续修改不同**：`CPA_API_KEY` 仅在远端没有 `config/config.yaml` 的第一次初始化时进入 Git。后续替换 HF Secret **不会**覆盖仓库里已有的 key。可在 OMC 中管理/轮换。
- **已有 Git 数据可能覆盖初始化设置**：若 `config/config.yaml` 已存在，`start.sh` 中的新模板不再生效。确保旧仓库配置仍让 CPA 监听 `127.0.0.1:8317`，且 OMC 在本机可以访问 CPA 管理 API；否则可能无法通过 Caddy 使用。
- **公开镜像不等于公开密钥**：镜像中没有 HF Secrets；运行期才读取。发布镜像为 Public 才方便 HF 匿名拉取。
- **OAuth 回调限制**：某些授权流程依赖额外本地端口，HF 单端口部署不一定支持，优先使用项目支持的远程授权流程或 API Key。
- **自动休眠**：CPU Basic Space 可能休眠，不适合要求 24/7 稳定可用的 API 服务。
- **版本兼容性**：OMC 要求 CPA v8.0.0+。`latest` 仅用于快速启动，长期使用请固定验证过的版本或 digest。

## References

- https://help.router-for.me/configuration/storage/git
- https://github.com/WizisCool/oh-my-cpa
- https://huggingface.co/docs/hub/spaces-sdks-docker
- https://huggingface.co/docs/hub/spaces-overview
- https://docs.github.com/en/actions/tutorials/publish-packages/publish-docker-images
