import 'package:get/get_rx/src/rx_types/rx_types.dart' show RxList;

extension RxListExt<E> on RxList<E> {
  void fillRangeOnly(int start, int end, [E? fill]) {
    // 上游的 getx fork 有不触发 reportRead 的 `rawValue`，鸿蒙锁定的 fork 还没有；
    // `value` 返回的就是内部那个 List，下标赋值同样不会触发 refresh。
    final list = value;
    final E filler = fill as E;
    for (int i = start; i < end; i++) {
      list[i] = filler;
    }
  }
}
