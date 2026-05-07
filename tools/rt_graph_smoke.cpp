#include "rt_graph.h"

int main() {
  RTGraph *g = rt_graph_create(16, 512);

  rt_graph_add_node(g, 0, 1); // sinosc
  rt_graph_add_node(g, 1, 2); // out

  rt_graph_set_control(g, 0, 0, 440.0f); // freq
  rt_graph_set_control(g, 1, 0, 0.0f);   // bus0

  rt_graph_connect(g, 0, 0, 1, 0);
  rt_graph_process(g, 128);

  rt_graph_destroy(g);
  return 0;
}
