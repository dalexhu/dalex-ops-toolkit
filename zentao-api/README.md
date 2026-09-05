# 禅道 REST API 测试（Bruno）

针对禅道 22.5 的 `api.php/v1` 做一轮常用接口的冒烟测试：换 token → 当前用户 → 产品/项目/执行 → 任务、Bug、需求、待办各做 list / create / get / (update) / delete。
创建的数据都以 `[api-test]` 开头并在同一轮里删除（禅道的 DELETE 是软删除）。

## 准备

```bash
cd zentao-api
cp .env.example .env        # 填 ZENTAO_PASSWORD=...（.env 已 git-ignore，不要提交）
```

环境：`environments/test83.bru`（83，`http://10.0.1.83:8080`）、`environments/pm75.bru`（75，`http://10.0.1.75`），账号都是 `alex`。

## 运行

```bash
bru run --env test83                       # 全部按目录顺序跑
bru run 05-tasks --env test83              # 只跑任务这一组（需要先有 token：加 01-auth）
bru run 01-auth 05-tasks --env test83
bru run --env test83 --reporter-html results.html   # 出报告
```

也可以用 Bruno 桌面版打开本目录（Open Collection），选环境后逐个发。

## 变量传递

- `token`：`01-auth/01-get-token` 的 post-response 脚本写入运行时变量，其余请求的 `Token` 头引用它。
- `productId` / `projectId` / `executionId`：由 list 请求从返回里挑第一个可用的（状态 normal/doing）写入；也可以在环境里预先固定。
- `taskId` / `bugId` / `storyId` / `todoId`：create 写入，delete 清空。

## 注意

- 登录失败会累计到禅道的账号锁定计数（默认 5 次锁 30 分钟），口令写错先别反复跑。
- `05-tasks/03-task-get` 顺便断言 deadline 原样返回，用来回归日期时区问题（前端补丁见 dalex-ops-lab `macmini-v2/host-readmes/zentao-patch-and-run.sh`）。
- 端点与必填字段来自容器内 `api/v1/entries/*.php`；完整列表在禅道「后台 → 二次开发 → API」。

## 09-scrum-flow：一个完整的 Scrum 迭代

`09-scrum-flow/` 用 API 走完一遍典型的敏捷开发流程，每轮自建一套独立数据、跑完全部删除，不碰已有产品和项目：

1. 建产品 → 建 Scrum 项目（`model: scrum`）→ 建产品计划（sprint backlog）
2. 提 3 条需求（待评审）→ 逐条评审通过（`/stories/:id/review`，状态变 active）→ 关联到产品计划
3. 建迭代（execution，2 周）→ 查看迭代需求列表
4. 每条需求各建 1 个任务（任务的 `story` 字段指向对应需求）
5. 任务 1：开始（`/start`，doing）→ 记录工时（`/estimate`）→ 完成（`/finish`，done）
6. 打版本（build）→ 针对该版本提 Bug → 确认 → 解决（fixed，指向该 build）→ 关闭
7. 写测试用例（含步骤和预期）→ 建测试单
8. 关闭需求 1（done）→ 迭代任务快照断言：3 个任务、其中 1 个 done
9. 逆序清理：测试单、用例、Bug、build、3 个任务、3 条需求、迭代、计划、项目、产品

```bash
bru run 01-auth 09-scrum-flow --env test83     # 需要 01-auth 先拿 token
```

### 过程中确认的 API v1 限制

- **需求关联进迭代**（22.5 原版做不到，已由本地补丁 3/4 修复）。原版三层原因：
  1. 路由表 `config/apiv1.php` 没有入口——`executionstories` / `projectstories` 都只有 `get()`，唯一的 linkstories 是 `/productplans/:id/linkstories`（关到产品计划）。
  2. 干活的 `executionModel::linkStories()` 只在网页流程里调用，且要用户在"是否关联计划下的需求"确认框点确认；API 的 `executions` POST 调 `$control->create($projectID)`，`$confirm` 用默认 `'no'`，永不执行。**给 API 传 `plans` 只挂计划，不拉需求**。
  3. 改调网页控制器也不行：`startSession()` 按是否 API 请求分别使用 `tmp/apisession` 和 `tmp/session` 两个会话目录，API token 在网页侧不可见，`Cookie` 或 `?zentaosid=` 都返回"登录已超时"。反向可以：API 请求能用 `Token: ss_<网页会话id>` 复用网页会话。

  4. **更关键的一层**：API 创建的项目 `storyType` 是空字符串（UI 建的是 `story`，表结构默认值也是 `story`，但入口没设这个字段），
     而 `executionModel::linkStory()` 用 `strpos($project->storyType, $story->type)` 过滤，空值会把**所有**需求跳过——
     这样的项目在网页上也一样关联不了需求，属于 `POST /projects` 的 bug。

  本地补丁（见 dalex-ops-lab `macmini-v2/host-readmes/zentao-patch-and-run.sh`）：
  - 补丁 3：给 `entries/executionstories.php` 增加 `post()` 与 `delete()`，于是 `POST /executions/:id/stories`（关联）和 `DELETE /executions/:id/stories/:storyID`（解除）可用；`post()` 照搬 `linkStories()` 先关项目再关迭代，`delete()` 调 `unlinkStory()` 并保留其约束。
  - 补丁 4：`entries/projects.php` 补上 `storyType`，默认 `story`。
  - 补丁 5：`config/apiv1.php` 增加两段式路由 `/executions/:id/stories/:storyID`（供解除关联用）。

  已提上游：关联/解除 [PR #199](https://github.com/easysoft/zentaopms/pull/199)、storyType [PR #198](https://github.com/easysoft/zentaopms/pull/198)。
  打补丁后 `09-scrum-flow` 的关联步骤返回 201，迭代需求列表 total=3。未打补丁的实例上 `12a` 会失败。
- **记录工时的路由是 `/tasks/:id/estimate`**（不是 `/recordestimate`），且受 `task-recordEstimate` 权限控制：非管理员且角色未授予该权限时返回 403（本例的 alex 即如此），断言对 403 容错。
- **记录工时只有公司管理员能用**（[issue #200](https://github.com/easysoft/zentaopms/issues/200)）：入口按控制器方法名 `task-recordWorkhour` 鉴权，而它**根本不是权限项**——`module/group/lang/allresources.php` 里 task 的 24 条权限只有 `recordEstimate`，`zt_grouppriv` 中 `recordWorkhour` 为 0 行，任何权限组都授不了，只剩 `getUserPriv()` 的公司管理员短路能过。同一入口的 `get()` 反而正确地优先走 `effort-createForObject`。83 上的处理是把 alex 加入公司管理员（`zt_company.admins`，**改完要重启容器**才生效）。注意工时日期不能晚于当天。
- 需求创建在产品强制评审时需要 `reviewer` 数组，成功返回 200（进入评审）而不是 201。

## 账号权限（83）

`alex` 原本不是公司管理员（`zt_company.admins` 只有 `,admin,`），只是加入了「管理员」等 7 个权限组（6901 条权限）。
2026-09-05 已把 alex 加入公司管理员：`update zt_company set admins=',admin,alex,' where id=1`，**改完必须重启 zentao 容器才生效**（PHP 侧缓存了公司信息，不重启仍返回 403）。
75（生产 `pm.mrmdamon.ca`）**未改动**，那里 alex 仍只是管理员组成员、不是公司管理员。

原因是下面这条 API 缺陷：记录工时的入口调用控制器 `task-recordWorkhour`，而权限表 `zt_grouppriv` 里根本没有这条权限（只有 `task-recordEstimate`），
任何权限组都无法授予，只有公司管理员能通过 `getUserPriv()` 的管理员短路。也就是说**普通成员无法通过 API 记录自己的工时**。

## 10-api-v2：API v2 冒烟测试

禅道同时提供 **v1**（`api.php/v1`，手写入口，增删改查齐全）和 **v2**（`api.php/v2`，声明式路由表 `config/apiv2.php`，把网页控制器包装成 JSON）。官方还有个 v2 的 TypeScript SDK：<https://github.com/easysoft/zentao-api>。

`10-api-v2/` 对 v2 做只读冒烟：产品列表与详情、迭代列表与详情、迭代任务、迭代需求、我的任务、任务详情、每页条数。

```bash
bru run 01-auth 10-api-v2 --env test83
```

22.5 上实测到的差异，写进了各请求的 docs：

- **v2 复用 v1 的 token**：`POST /api.php/v1/tokens` 拿到的值，同样以 `Token` 头发给 v2。不带 Token 时 v2 返回 401（用 curl 单独验证；bru 运行器整轮共用 cookie，断不出 401，故未写成断言）。
- **返回信封不同**：v2 统一是 `{status: "success", <载荷>, pager}`，v1 返回裸对象。
- **详情一次给多块数据**：如 `GET /products/:id` 同时返回 `product,dynamics,members,branches,reviewers`。
- **分页**：`recPerPage` 控制每页条数有效；`page` / `pageID` 在 22.5 上不改变 `offset`，翻页方式待确认。
- **v2 以读为主**：188 条路由里只有 68 条声明了写方法，且不含本集合关心的写操作——删除任务、关联/解除迭代需求、记录工时在 v2 里**都没有路由**（`estimate`、`effort` 关键字一条都搜不到）。所以写操作仍然只能走 v1，本仓库对 v1 的修补依然必要。

## 11-testcase-results：用例结果回写闭环

外部写测试代码、把结果写回禅道，**只能用 v1**：`POST /testcases/:id/results`。v2 的路由表和官方 SDK 文档都没有 testresult 模块（v2 只有测试用例 8 个操作、测试单 4 个操作，全是读和编辑用例本身）。

本目录每轮自建产品和用例，跑完删除，验证完整闭环：建用例（两个步骤）→ 读回步骤 → 提交一次"第二步失败"→ 读回确认整体为 fail 且每步结果和实际情况都在 → 再提交一次全通过 → 确认历史保留多条执行记录。

```bash
bru run 01-auth 11-testcase-results --env test83
```

### 调用要点

```bash
curl -X POST -H "Token: $TOK" -H 'Content-Type: application/json' \
  -d '{"steps":[{"result":"pass","real":"表单正常显示"},{"result":"fail","real":"报 500"}]}' \
  "$BASE/testcases/3626/results?testtask=0"
```

- **步骤按顺序匹配，不是按 id**：`steps[N]` 对应用例第 N 个步骤，所以每轮跑之前重新 `GET /testcases/:id` 取步骤，别缓存映射。从 `getStepIDList()` 的实现看，分组（group）类型的步骤也占一个位置，这一点未实测。
- **`?testtask=<测试单id>`** 把这次执行挂到测试单上并推进其进度；不带（或 0）就是一次独立的用例执行记录。
- **`?version=`** 默认取用例当前版本。
- **用例整体结论由步骤结果推导**（有一步 fail 即 fail），不用自己算。
- 同一用例可反复回写，每次一条新记录，`GET /testcases/:id/results` 返回全部历史。

另有两个专用回写入口，普通脚本用不到：`/ztf/submitResult` 是禅道自家 ZTF 自动化框架的回传口，认证走 `Authorization: Bearer <自动化执行机令牌>` 而不是用户 token；`/ciresults` 供 CI 流水线使用。

## 已知问题（禅道 22.5，2026-09-05 在 83 上验证）

- **`DELETE /tasks/{id}` 不删任务**（原版 22.5）：返回 `{"message":"success"}`，但任务仍在（`deleted=0`）。原因是 `api/v1/entries/task.php` 仍按旧签名调用 `$control->delete(0, $taskID, 'true')`，而 `module/task/control.php` 的 `delete($taskID, $from)` 已改签名，任务 ID 被当成 0。`05-tasks/06-task-verify-deleted` 专门暴露这个问题。83 和 75 已通过容器启动补丁修复（dalex-ops-lab `macmini-v2/host-readmes/zentao-patch-and-run.sh`），上游 PR easysoft/zentaopms#196。在未打补丁的实例上它会失败并**每轮留下一个 `[api-test]` 任务**，清理：
  `docker exec zentao-db bash -c 'mariadb -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" "$MARIADB_DATABASE" -e "update zt_task set deleted=\"1\" where name like \"[api-test]%\""'`
- `GET /products/{id}/stories` 返回 201 而不是 200；`POST /products/{id}/stories` 在产品强制评审时需要 `reviewer` 数组，创建成功返回 200（进入评审）而不是 201。断言已按此放宽。
- 返回体里的 `id` 等数字字段都是字符串。

## 环境选择

集合会从列表里挑第一个 `doing` 的项目/执行和 `normal` 的产品来建测试数据。83 是演练实例可以随便跑；**75（pm75）是现网，跑之前请在环境文件里把 `productId`、`projectId`、`executionId` 固定到专门的测试产品/项目**，否则测试任务会落到真实迭代里（而且因为上面的删除 bug 删不掉）。

## 最近一次结果（test83）

2026-09-05（83 打补丁后）：全量 88 个请求、147 个断言全部通过（含工时记录、需求关联与解除关联、v2 冒烟、用例结果回写）（含 09-scrum-flow 的 42 个请求 / 62 个断言）；打补丁前只有 `task verify deleted` 失败。
