# 调研：Legado MD3 阅读进度存储 / 恢复链路

来源仓库：`/root/data/workspaces/doro_FriendMessage_641981595/legado-with-MD3`（Kotlin）。

## 1. 进度的最小单位 = 章节索引 + 章内字符 offset

**`Book.kt` (L93-L107)**

```kotlin
// 当前章节名称
var durChapterTitle: String? = null,
// 当前章节索引
@ColumnInfo(defaultValue = "0")
var durChapterIndex: Int = 0,
// 当前阅读的进度(首行字符的索引位置)
@ColumnInfo(defaultValue = "0")
var durChapterPos: Int = 0,
// 最近一次阅读书籍的时间(打开正文的时间)
@ColumnInfo(defaultValue = "0")
var durChapterTime: Long = System.currentTimeMillis(),
```

**结论**：`durChapterPos` 是**章内首行字符的章内偏移**，不是页码、不是段落 idx。

## 2. 恢复链路：char offset → page index

**`ReadBook.kt` (L595-L598)**

```kotlin
val durPageIndex: Int
    get() {
        return curTextChapter?.getPageIndexByCharIndex(durChapterPos) ?: 0
    }
```

**`TextChapter.kt` (L226-L243)** 用每页 `chapterPosition` 字段做二分搜索：

```kotlin
fun getPageIndexByCharIndex(charIndex: Int): Int {
    val pageSize = pages.size
    if (pageSize == 0) {
        return -1
    }
    val bIndex = pages.takeIf { it.isNotEmpty() }?.fastBinarySearchBy(charIndex, 0, pageSize) {
        it.chapterPosition
    } ?: 0
    val index = abs(bIndex + 1) - 1
    if (!isCompleted && index == pageSize - 1) {
        val page = pages[index]
        val pageEndPos = page.chapterPosition + page.charSize
        if (charIndex > pageEndPos) {
            return -1
        }
    }
    return index
}
```

每个 `TextPage` 必须带 `chapterPosition`（首字符章内 offset）+ `charSize`（页内字符总数）字段才能反算。

## 3. 反向：pageIndex → char offset（用于保存）

**`TextChapter.kt` (L113-L116)**

```kotlin
fun getReadLength(pageIndex: Int): Int {
    if (pageIndex < 0) return 0
    return pages[min(pageIndex, lastIndex)].chapterPosition
}
```

要保存"当前是第 N 页"时：取 `pages[N].chapterPosition` 写到 `book.durChapterPos`。

## 4. 章内翻页的存储时机：每翻一页立即写

**`ReadBook.moveToNextPage` (L396-L410)**

```kotlin
fun moveToNextPage(): Boolean {
    var hasNextPage = false
    curTextChapter?.let {
        val nextPagePos = it.getNextPageLength(durChapterPos)
        if (nextPagePos >= 0) {
            hasNextPage = true
            it.getPage(durPageIndex)?.removePageAloudSpan()
            durChapterPos = nextPagePos
            callBack?.cancelSelect()
            callBack?.upContent()
            saveRead(true)   // ← 每页都存，pageChanged=true 跳过章节标题刷新
        }
    }
    return hasNextPage
}
```

**`ReadBook.moveToPrevPage` (L412-L424)** 同。

**`saveRead` (L1021-L1044)** 异步写 DB：

```kotlin
fun saveRead(pageChanged: Boolean = false) {
    val book = book ?: return
    executor.execute {                       // ← 异步线程
        kotlin.runCatching {
            book.lastCheckCount = 0
            book.durChapterTime = System.currentTimeMillis()
            val chapterChanged = book.durChapterIndex != durChapterIndex
            book.durChapterIndex = durChapterIndex
            book.durChapterPos = durChapterPos
            if (!pageChanged || chapterChanged) {
                appDb.bookChapterDao.getChapter(book.bookUrl, durChapterIndex)?.let {
                    book.durChapterTitle = it.getDisplayTitle(...)
                }
            }
            book.update()
        }
    }
}
```

**结论**：异步线程写，**没有 debounce**。每翻一页就提交一个 IO 任务。

## 5. 启动恢复（resetData）

**`ReadBook.kt` (L118-L146 节选)**

```kotlin
fun resetData(book: Book) {
    ReadBook.book = book
    ...
    durChapterIndex = book.durChapterIndex
    durChapterPos = book.durChapterPos                 // ← 从 DB 拷字段
    isLocalBook = book.isLocal
    clearTextChapter()
    callBack?.upContent()
}
```

`loadContent` 完成 typeset → `durPageIndex` getter 自动反算 → UI 显示正确页。

## 6. 跳页 / 远端进度同步

- `setProgress(BookProgress)` (L215-L227)：远端 sync / 书签跳回，调 `saveRead()`（无 pageChanged，会写章节标题）。
- `skipToPage(index)` (L513-L520)：从目录跳页，`durChapterPos = curTextChapter?.getReadLength(index) ?: index`，再 `saveRead(true)`。

---

## 对照：当前 Flutter 实现

| MD3 (Kotlin) | Flutter 当前 | gap |
|---|---|---|
| `Book.durChapterPos` (Int char offset) | `SavedReadingProgress.offset` (字段已存在) | 复用现有字段，不新增 schema |
| `TextPage.chapterPosition` | `TextPage` 没有 chapterPosition 字段 | **需要补**：page_measure 时累加段长度 |
| `TextChapter.getPageIndexByCharIndex` | `PageViewController` 没有该方法 | **需要新增** |
| `moveToNextPage` 立即 `saveRead(true)` | `_onPageChanged` 只 `setState` 不存 | **需要补**：listener 加保存调用 |
| `resetData` 从 DB 恢复 | `initState` 不读 DB | **需要补**：initState 调 `progressService.load` |
