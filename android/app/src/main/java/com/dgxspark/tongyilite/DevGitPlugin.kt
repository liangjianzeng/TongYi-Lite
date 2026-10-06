/**
 * DevGitPlugin — 本地 git 操作（JGit 进程内，零 exec）。
 *
 * 为什么 JGit：targetSdk 34 W^X 限制下 app 不能 exec 数据目录二进制，
 * 没有 git 可执行文件；JGit 是进程内 Java 库（EDL 许可），clone/commit/push
 * 全部内存中完成。ssh:// 远端不支持（明确报错，引导走 Termux/远程工作区）。
 *
 * 所有方法阻塞执行（调用方持独立线程池），返回 map {ok, output}。
 */
package com.dgxspark.tongyilite

import org.eclipse.jgit.api.CloneCommand
import org.eclipse.jgit.api.Git
import org.eclipse.jgit.transport.UsernamePasswordCredentialsProvider
import java.io.File

object DevGitPlugin {

    /** 按工具语义打开仓库；非仓库/损坏 → ok=false 带可读原因。 */
    private fun open(root: String): Git = Git.open(File(root))

    private fun ok(output: String): Map<String, Any> =
        mapOf("ok" to true, "output" to output)

    private fun fail(output: String): Map<String, Any> =
        mapOf("ok" to false, "output" to output)

    private fun err(e: Exception): Map<String, Any> {
        val msg = e.message ?: e.javaClass.simpleName
        return fail("git 操作失败：${e.javaClass.simpleName}: $msg")
    }

    private fun creds(username: String?, password: String?) =
        if (!username.isNullOrEmpty() && !password.isNullOrEmpty()) {
            UsernamePasswordCredentialsProvider(username, password)
        } else null

    fun status(root: String): Map<String, Any> = try {
        val git = open(root)
        git.use { g ->
            val s = g.status().call()
            val branch = try {
                g.repository.branch
            } catch (_: Exception) { "" }
            val sb = StringBuilder()
            sb.append("## ").append(branch).append('\n')
            for (e in s.added) sb.append("A  ").append(e).append('\n')
            for (e in s.changed) sb.append("M  ").append(e).append('\n')
            for (e in s.removed) sb.append("D  ").append(e).append('\n')
            for (e in s.untracked) sb.append("?? ").append(e).append('\n')
            for (e in s.missing) sb.append(" - ").append(e).append('\n')
            ok(sb.toString().trim())
        }
    } catch (e: Exception) {
        if (e.message?.contains("Not a git repository", ignoreCase = true) == true ||
            File(root, ".git").let { !it.exists() }
        ) fail("NOT_A_GIT_REPO（$root）") else err(e)
    }

    fun diff(root: String, staged: Boolean, file: String?): Map<String, Any> = try {
        val git = open(root)
        git.use { g ->
            val cmd = if (staged) g.diff().setCached(true) else g.diff()
            if (!file.isNullOrEmpty()) {
                cmd.setPathFilter(org.eclipse.jgit.treewalk.filter.PathFilter.create(file))
            }
            val out = StringBuilder()
            for (d in cmd.call()) out.append(d).append('\n')
            ok(out.toString().trim().ifEmpty { "（无改动）" })
        }
    } catch (e: Exception) {
        err(e)
    }

    fun log(root: String, n: Int): Map<String, Any> = try {
        val git = open(root)
        git.use { g ->
            val out = StringBuilder()
            for (c in g.log().setMaxCount(n.coerceIn(1, 50)).call()) {
                out.append(c.abbreviate(8).name())
                    .append(' ')
                    .append(c.shortMessage).append('\n')
            }
            ok(out.toString().trim().ifEmpty { "（暂无提交）" })
        }
    } catch (e: Exception) {
        err(e)
    }

    fun commit(root: String, files: List<String>, message: String): Map<String, Any> = try {
        val git = open(root)
        git.use { g ->
            if (files == listOf(".")) {
                g.add().addFilepattern(".").call()
            } else {
                val add = g.add()
                for (f in files) add.addFilepattern(f)
                add.call()
            }
            val result = g.commit().setMessage(message).call()
            ok("已提交 ${result.shortMessage ?: message}（${result.name.take(8)}）")
        }
    } catch (e: Exception) {
        err(e)
    }

    fun push(
        root: String,
        remote: String,
        branch: String?,
        username: String?,
        password: String?,
    ): Map<String, Any> = try {
        val git = open(root)
        git.use { g ->
            val config = g.repository.config
            // 无 remote 配置（刚 init/clone 自文件系统）：给出可读提示。
            val url = config.getString("remote", remote, "url")
            if (url.isNullOrEmpty()) {
                return@use fail("远端 $remote 未配置（git remote add $remote <url>）")
            }
            if (url.startsWith("git@") || url.startsWith("ssh://")) {
                return@use fail("本地工作区仅支持 https 远端（当前 $remote 为 ssh）。"
                        + "请改用 https，或切 Termux/远程工作区")
            }
            val cmd = g.push().setRemote(remote)
            if (!branch.isNullOrEmpty()) cmd.setRefSpecs(
                org.eclipse.jgit.transport.RefSpec("refs/heads/$branch:refs/heads/$branch")
            )
            creds(username, password)?.let { cmd.setCredentialsProvider(it) }
            val results = cmd.call()
            val sb = StringBuilder()
            for (r in results) {
                for (u in r.remoteUpdates) {
                    sb.append(u.remoteName).append(':').append(u.status).append(' ')
                }
            }
            ok("已推送到 $remote ${sb.toString().trim()}")
        }
    } catch (e: Exception) {
        err(e)
    }

    fun clone(
        url: String,
        target: String,
        username: String?,
        password: String?,
        branch: String?,
        depth: Int?,
    ): Map<String, Any> {
        if (url.startsWith("git@") || url.startsWith("ssh://")) {
            return fail("本地工作区仅支持 https 克隆（当前 url 为 ssh）。"
                    + "请改用 https 地址，或切 Termux/远程工作区")
        }
        return try {
            val cmd: CloneCommand = Git.cloneRepository()
                .setURI(url)
                .setDirectory(File(target))
            if (!branch.isNullOrEmpty()) cmd.setBranch(branch)
            // 浅克隆（JGit 6.10 CloneCommand.setDepth）：大仓库只拉最近 N 层
            // 提交。浅克隆历史不完整——读代码/分析够用，不能 push。
            if (depth != null && depth > 0) cmd.setDepth(depth)
            creds(username, password)?.let { cmd.setCredentialsProvider(it) }
            val git = cmd.call()
            git.use { g -> ok("克隆完成：${g.repository.branch}") }
        } catch (e: Exception) {
            err(e)
        }
    }
}
