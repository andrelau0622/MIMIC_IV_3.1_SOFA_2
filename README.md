# MIMIC-IV SOFA-2 一键生成

本项目提供了一个用于在 **MIMIC-IV (v3.1)** 数据库中一键提取 **SOFA-2 (Sequential Organ Failure Assessment 2.0)** 评分的整合版 SQL 脚本。

基于原始的开源 SOFA-2 提取逻辑，本项目进行了高度整合与优化，特别适合使用 DBeaver 等图形化数据库客户端的医学研究人员。

## 核心特性 (Features)

*   **一键运行 (One-Click Execution)**：摒弃了繁杂的多步骤 SQL 脚本，将所有计算逻辑（包括环境清理、时间网格构建、各器官评分计算、窗口聚合等）整合成单一的 SQL 脚本。
*   **内置严重 Bug 修复 (Built-in Patch)**：已经自动集成了原版代码中缺失的 **肾脏评分三窗口尿量 (6h/12h/24h)** 和 **Virtual RRT** 的判定补丁，确保输出结果的准确性。
*   **完全对标官方 Schema**：输出的表结构与 MIMIC-IV 官方 `mimiciv_derived` 中的 `first_day_sofa` 高度对齐，可直接替换原有研究代码中的依赖。

---

## 环境依赖 (Prerequisites)

在运行本脚本之前，请确保您的数据库环境满足以下条件：

1.  已成功安装 **PostgreSQL** 并导入了完整版的 **MIMIC-IV v3.1** 数据。
2.  已成功运行官方的 MIT-LCP MIMIC-IV Concepts 脚本，确保 `mimiciv_derived` 模式中包含基础的衍生表（如 `gcs`, `bg`, `vasoactive_agent`, `urine_output`, `ventilation` 等）。

---

## 使用指南 (Usage)

### 方法一：使用 DBeaver（推荐）
1. 打开 DBeaver，连接到您的 MIMIC-IV 数据库。
2. 新建一个 SQL 编辑器窗口。
3. 复制本项目中的完整 SQL 代码并粘贴到编辑器中。
4. 点击工具栏的 **“执行 SQL 脚本 (Execute SQL Script / Alt+X)”**。
5. 等待运行完成，右键刷新 `mimiciv_derived` 模式，即可看到新生成的表。

### 方法二：使用 psql 命令行
如果您习惯使用命令行，可以通过以下命令直接运行：
```bash
psql -h YOUR_HOST -U YOUR_USER -d YOUR_DATABASE -f sofa2_one_click.sql

```

---

## 输出结果 (Outputs)

代码运行完毕后，会在 **`mimiciv_derived`** 模式 (Schema) 下生成以下关键数据表，可直接用于您的统计分析与建模：

| 表名 (Table Name) | 描述 (Description) |
| --- | --- |
| **`first_day_sofa2`** | 包含**患者入科首日的 SOFA-2 各维度分数**（呼吸、凝血、肝脏、心血管、神经、肾脏及总分）。字段结构完全对标官方的 `first_day_sofa` 表。 |
| **`sepsis3_sofa2_delta`** | 包含**通过 SOFA-2 判定并发 Sepsis 3.0 的队列**数据。该表结合了患者的疑似感染时间 (Suspicion of Infection) 和 SOFA-2 变化量 (Delta ≥ 2) 自动生成。 |
| **`sofa2_scores`** | 包含 24 小时滚动窗口的最终 SOFA-2 评分，可用于追踪逐小时（`hr`）的病情动态变化。 |
| **`sofa2_hourly_raw`** | 细粒度的逐小时原始评分记录（未经过滑动窗口平滑），主要用于底层数据核对与调试。 |

---

## 致谢 (Acknowledgments)

* 本项目底层逻辑与代码基于开源项目 [wzwxh2023/SaAki_Sofa_benchmark](https://github.com/wzwxh2023/SaAki_Sofa_benchmark) 提取与重构。


* 感谢 MIT-LCP 团队提供的 [MIMIC-IV](https://mimic.mit.edu/) 数据库及其庞大的开源生态。
