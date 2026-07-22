// ============================================================================
// MemorySize.scala — 内存大小辅助类
//
// case class MemorySize(bytes): 以字节为单位存储容量，提供 kBytes/KBytes 转换方法返回 KB/MB 数值
// 伴生对象: fromBytes / fromKBytes / fromMBytes 工厂方法
// ============================================================================
package coralnpu

/** 内存大小包装类 — bytes ↔ KB/MB 转换 */
case class MemorySize(bytes: Int) {
  def kBytes: Int = bytes / 1024
  def KBytes: Int = kBytes  //别名
}
/** MemorySize 伴生对象 — 工厂方法 */
object MemorySize {
  def fromBytes(bytes: Int): MemorySize = MemorySize(bytes)
  def fromKBytes(kBytes: Int): MemorySize = MemorySize(kBytes * 1024)
  def fromMBytes(mBytes: Int): MemorySize = MemorySize(mBytes * 1024 * 1024)
}
