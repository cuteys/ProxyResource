# VLESS WS TLS 新增「自签证书」设计方案

- 日期：2026-11-28
- 状态：已实现并通过全部验收（2026-11-28）
- 对象：Sing-Box/singbox.sh（vlessws 协议证书来源）
- 定位：自签证书仅服务套 CDN 场景（源站证书），直连场景不可用

## 一、目标与边界

- 证书来源菜单由两项扩展为三项：ACME / 自备证书 / 自签生成。
- 自签证书由脚本 openssl 现场生成，10 年有效期，不做续签、不做重新生成菜单。
- 自签证书面向 CDN 回源：客户端验证 CDN 边缘证书，分享链接不追加 allowInsecure 类字段。
- 改域名的既有口径是删除协议后重装，重装自签时以新绑定域名重新生成并覆盖旧文件。
- 只改 vlessws 协议内部分支，不动其他协议与其他菜单。

## 二、现状锚点

| 触点 | 位置 | 现行为 |
| :--- | :--- | :--- |
| 证书来源询问 | prompt_vlessws_cert_source | acme / custom 二选一 |
| 模式判定 | vlessws_effective_cert_mode | 状态文件优先，缺状态时嗅探片段 certificate_path 记 custom |
| 顶层证书签发器 | render_certificate_providers | custom 模式跳过渲染，acme 模式渲染 certificate_providers |
| 片段 TLS 写法 | write_vlessws_fragment | custom 写 certificate_path/key_path，acme 写 certificate_provider 引用 |
| 防火墙 | add_firewall_rule_once / print_firewall_port_status | 仅 acme 模式放行 80 |
| 迁出保护 | vlessws_record_cert_rescue + 卸载/删除分支 | custom 证书登记 /var/lib/sing-box-certs-rescue 原位保留 |
| 客户端展示 | write_vlessws_client | custom 显示自备证书路径与 CF SSL 口径提示 |
| 80 端口占用预检 | install_vlessws_protocol | 仅 acme 模式警告 80 被占用 |

## 三、设计

### 3.1 交互

prompt_vlessws_cert_source 增加选项 3「自签生成（套 CDN 场景）」：

- 不追问任何证书文件路径，直接以绑定域名生成；
- 选定后置 vlessws_cert_mode=selfsigned，cert_path/key_path 由脚本内定，不再交互。

### 3.2 证书生成

- 新增 generate_vlessws_selfsigned_cert 函数，安装时每次调用，生成即覆盖旧文件：
  - 算法 ECDSA P-256，有效期 3650 天；
  - CN 与 SAN 均为当前绑定域名 vlessws_domain（DNS 形态，不含 IP）；
  - 落盘 CONFIG_DIR/certs/vlessws-selfsigned.crt 与 vlessws-selfsigned.key，key 权限 600；
  - 目录由 ensure_state_dirs 一并创建；
  - openssl 缺失时沿用 install_package_if_missing openssl 补装口径。
- 生成后复用现有 PEM 哈希匹配校验与 SAN 覆盖软警告（vlessws_cert_pubkey_hash 等三件套），校验不过即中止安装，不写任何配置。
- 重新安装时覆盖旧文件即为「改域名自签新域名」的实现，无需额外菜单。

### 3.3 配置注入

- write_vlessws_fragment：selfsigned 与 custom 同形态，写 certificate_path/key_path，不写 certificate_provider 引用。
- render_certificate_providers：跳过条件从等于 custom 放宽为不等于 acme（即 custom 与 selfsigned 均不渲染顶层 certificate_providers）。
- 红线：不引入悬空 provider 引用；注入后必须真机 run 冒烟，不能只过 sing-box check。

### 3.4 模式判定

vlessws_effective_cert_mode 判定顺序调整为：

1. 状态文件优先，读出 acme/custom/selfsigned；
2. 缺状态时嗅探片段：有 certificate_path 且路径含 vlessws-selfsigned 记 selfsigned，否则记 custom；
3. 兜底 acme。

状态文件 vlessws.env 增写 selfsigned 时 cert_path/key_path 两个键，load_vlessws_state 与 write_vlessws_state 相应兼容，空值回退口径不变。

### 3.5 防火墙

- 80 端口放行与占用预检维持「仅 acme」判断不动，selfsigned 天然不触发。
- 无新增端口。

### 3.6 迁出保护

- 自签证书可再生，不进迁出保护链路：vlessws_record_cert_rescue 的登记闸门维持等于 custom 不变，selfsigned 删除协议/卸载时随脚本生成物一并清理。
- 嗅探误判兜底：状态文件丢失且嗅探为 selfsigned 时，不登记迁出清单。

## 3.7 客户端输出与文案

- write_vlessws_client 自签分支：
  - 显示「证书类型：自签证书（10 年，套 CDN 场景专用，直连不可用）」；
  - CDN 提示：源站为自签证书时 CDN 的 SSL 模式须配 Full，不可用 Full strict；
  - 分享链接与明文参数不追加 allowInsecure/skip-cert-verify/insecure 任何字段，与 acme/custom 口径一致。
- 节点信息中的证书来源文案同步 selfsigned 分支。

## 四、改动清单

| 序号 | 函数/文件 | 改动 |
| :--- | :--- | :--- |
| 1 | prompt_vlessws_cert_source | 增选项 3，自签分支置 mode 与内定路径 |
| 2 | generate_vlessws_selfsigned_cert（新增） | openssl 生成 ECDSA P-256 自签对 |
| 3 | install_vlessws_protocol | 自签模式安装前调用生成函数并跑哈希/SAN 校验 |
| 4 | vlessws_effective_cert_mode | 判定顺序增 selfsigned 嗅探 |
| 5 | write_vlessws_state / load_vlessws_state | 兼容 selfsigned 与路径键 |
| 6 | write_vlessws_fragment | selfsigned 走 certificate_path 分支 |
| 7 | render_certificate_providers | 跳过条件改为非 acme |
| 8 | write_vlessws_client | 自签展示与 CDN 提示分支 |
| 9 | ensure_state_dirs | 创建 CONFIG_DIR/certs |

不动：防火墙两处、迁出保护登记闸门、卸载主流程、安装菜单枚举、状态面板协议枚举。

## 五、测试与验收

1. bash -n 语法校验。
2. Docker 容器内函数级测试：source 后断言 CONFIG_DIR 指向测试目录，确认宿主机 /etc/sing-box 非生产环境方可开测；覆盖用例：
   - 自签生成：SAN 覆盖绑定域名、10 年有效期、EC 密钥、key 权限 600；
   - 片段渲染：selfsigned 出 certificate_path/key_path 且无 certificate_provider；
   - render_certificate_providers：selfsigned 不出顶层签发器；
   - effective_cert_mode：状态优先、文件名嗅探、兜底 acme 三态；
   - 改域名重装：旧自签文件被新域名证书覆盖；
   - 卸载/删除：selfsigned 不登记迁出清单且文件随生成物清理，custom 行为不变。
3. 真机（Docker 内 sing-box check + run 冒烟）：自签形态 check 通过且 run 不 FATAL。
4. 独立子代理复核 diff 后再回报主人。

## 六、交付纪律

- 备份 singbox.sh 至 ~/.hermes/backups/ 按版本命名后再动刀。
- 测试产物与临时容器用后清理。
- 提交信息采用 type: 小写英文祈使短句，如 feat: add self-signed certificate source for vless ws。
