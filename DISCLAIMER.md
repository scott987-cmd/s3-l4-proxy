# 免责声明 / Disclaimer

简体中文 | [English](#disclaimer-english)

## 免责声明

**按「现状」提供。** 本项目及其全部文档按「现状」（AS IS）提供，不附带任何明示或默示的担保，包括但不限于对适销性、特定用途适用性与非侵权的担保。在适用法律允许的最大范围内，作者与贡献者不对因使用或无法使用本项目而产生的任何直接、间接、偶然、特殊、惩罚性或后果性损失承担责任，包括但不限于业务中断、数据丢失与收入损失。完整条款以 [LICENSE](LICENSE)（Apache-2.0）为准；本文件与 LICENSE 不一致时，以 LICENSE 为准。

**性能数据不构成承诺。** 文档中出现的吞吐、巡检与验证结果，来自特定环境下的一次实测——特定的实例规格、网络条件与对象存储组合——仅用于说明方案可行性。这些数字**不代表**你的环境能够达到的性能，也**不构成**任何形式的性能承诺、容量保证或服务等级协议。任何容量结论都必须以你自己环境中的压测为准。

**会修改系统状态。** 部署脚本会安装软件包，并修改 nginx 配置、systemd 限制、sysctl 参数、日志轮转策略与防火墙规则。脚本在改动前创建运行级备份并在失败时自动回滚，但这不能替代你自己的验证：请先在非生产环境完整演练，确认你具备相应的变更授权，并准备好回滚方案。启用出向锁定（`EGRESS_LOCK=1`）前，务必先枚举该主机的全部出网依赖。

**上线前必须自行验证。** 厂商兼容性指的是 TCP/TLS **数据面**兼容，不代表不同厂商的认证协议天然互通。正式承载业务前，必须使用你自己的 SDK/CLI 完成 PUT、GET、HEAD、Multipart 与数据完整性验证。

**安全与合规由使用者负责。** 你需要自行评估该架构是否满足你所处行业与地区的安全、合规、数据保护及跨境数据传输要求。文档中的安全建议属于通用工程实践，**不构成法律、合规或审计意见**。涉及个人信息或受监管数据时，请咨询你的法务与合规团队。

**无厂商隶属关系。** 本项目与任何云服务商、对象存储厂商或负载均衡产品提供方均无隶属、赞助或背书关系。文中出现的产品名称与商标归各自所有者所有，仅用于说明兼容性与配置示例。

**无支持义务。** 本项目按开源方式发布，不附带任何支持、维护或更新义务，也不保证缺陷会被修复。

---

<a id="disclaimer-english"></a>

## Disclaimer (English)

[简体中文](#免责声明) | English

**Provided as is.** This project and all of its documentation are provided "AS IS", without warranty of any kind, express or implied, including but not limited to the warranties of merchantability, fitness for a particular purpose and non-infringement. To the maximum extent permitted by applicable law, the authors and contributors shall not be liable for any direct, indirect, incidental, special, exemplary or consequential damages arising from the use of or inability to use this project, including business interruption, data loss and loss of revenue. The governing terms are in [LICENSE](LICENSE) (Apache-2.0); where this file and the LICENSE differ, the LICENSE controls.

**Performance figures are not a commitment.** The throughput, inspection and verification results in this documentation come from a single measurement in one specific environment — a particular instance size, network path and object storage combination — and serve only to show that the design works. They do **not** represent what your environment will achieve and do **not** constitute a performance commitment, capacity guarantee or service level agreement. Any capacity conclusion must come from load testing in your own environment.

**It changes system state.** The deployment scripts install packages and modify nginx configuration, systemd limits, sysctl parameters, log rotation and firewall rules. They take a run-level backup before making changes and roll back automatically on failure, but that is not a substitute for your own validation: rehearse in a non-production environment first, confirm you hold the necessary change authorisation, and have a rollback plan. Before enabling the egress lock (`EGRESS_LOCK=1`), enumerate every outbound dependency of the host.

**Validate before you go live.** Vendor compatibility here means TCP/TLS **data-plane** compatibility. It does not imply that different vendors' authentication protocols interoperate. Before carrying production traffic, complete PUT, GET, HEAD, multipart and integrity verification with your own SDK or CLI.

**Security and compliance are your responsibility.** You are responsible for assessing whether this architecture meets the security, compliance, data-protection and cross-border data transfer requirements of your industry and jurisdiction. The security guidance in this documentation is general engineering practice and does **not** constitute legal, compliance or audit advice. Where personal or regulated data is involved, consult your own legal and compliance teams.

**No vendor affiliation.** This project is not affiliated with, sponsored by or endorsed by any cloud provider, object storage vendor or load balancer product. Product names and trademarks belong to their respective owners and appear only to describe compatibility and configuration examples.

**No support obligation.** This project is released as open source with no obligation of support, maintenance or updates, and no guarantee that defects will be fixed.
