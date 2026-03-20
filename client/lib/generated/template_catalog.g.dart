// GENERATED — do not edit. Run: edd build client
// Generated from packages/epyx/src/epyx/core/template.py

class TemplateInfo {
  final String name;
  final String description;
  final int numPanes;
  final List<String> slotNames;
  final String bestFor;
  final bool isFavorite;
  final List<Map<String, dynamic>> slots;

  const TemplateInfo({
    required this.name,
    required this.description,
    required this.numPanes,
    required this.slotNames,
    required this.bestFor,
    required this.isFavorite,
    required this.slots,
  });

  @override
  String toString() => 'TemplateInfo($name)';
}

const kTemplateCatalog = <TemplateInfo>[
  TemplateInfo(
    name: 'Simple-Three-Pane',
    description: 'Classic three-pane: inputs | outputs | other',
    numPanes: 3,
    slotNames: ['inputs', 'main_output', 'other'],
    bestFor: 'interactive calculators',
    isFavorite: true,
    slots: <Map<String, dynamic>>[{'name': 'inputs', 'preferred_usages': ['input'], 'preferred_roles': ['parameter', 'setting']}, {'name': 'main_output', 'preferred_usages': ['output'], 'preferred_roles': ['visualization', 'display', 'monitor']}, {'name': 'other'}],
  ),
  TemplateInfo(
    name: 'Simple-Two-Pane',
    description: 'Two-pane split: inputs | outputs',
    numPanes: 2,
    slotNames: ['inputs', 'output'],
    bestFor: 'interactive calculators',
    isFavorite: false,
    slots: <Map<String, dynamic>>[{'name': 'inputs', 'preferred_usages': ['input'], 'preferred_roles': ['parameter', 'setting']}, {'name': 'output'}],
  ),
  TemplateInfo(
    name: 'Simple-Single-Pane',
    description: 'Single scrollable pane for all controls',
    numPanes: 1,
    slotNames: ['all'],
    bestFor: 'simple models with few controls',
    isFavorite: false,
    slots: <Map<String, dynamic>>[{'name': 'all'}],
  ),
  TemplateInfo(
    name: 'Tabbed',
    description: 'Tabbed groups: Inputs, Charts, Tables, Other',
    numPanes: 4,
    slotNames: ['Inputs', 'Charts', 'Tables', 'Other'],
    bestFor: 'data visualization dashboards, complex models with many controls',
    isFavorite: false,
    slots: <Map<String, dynamic>>[{'name': 'Inputs', 'preferred_usages': ['input'], 'preferred_roles': ['parameter', 'setting']}, {'name': 'Charts', 'preferred_usages': ['output'], 'preferred_roles': ['visualization', 'monitor'], 'preferred_kinds': ['plot']}, {'name': 'Tables', 'preferred_usages': ['table'], 'preferred_roles': ['data'], 'preferred_kinds': ['table']}, {'name': 'Other'}],
  ),
  TemplateInfo(
    name: 'Grid',
    description: 'Responsive card grid for dashboard overview',
    numPanes: 1,
    slotNames: ['all'],
    bestFor: 'overview dashboards',
    isFavorite: false,
    slots: <Map<String, dynamic>>[{'name': 'all'}],
  ),
  TemplateInfo(
    name: 'Focus',
    description: 'Sidebar (20%) + main focus area (80%)',
    numPanes: 2,
    slotNames: ['sidebar', 'main'],
    bestFor: 'presentation-style layouts',
    isFavorite: false,
    slots: <Map<String, dynamic>>[{'name': 'sidebar', 'preferred_usages': ['input'], 'preferred_roles': ['parameter', 'setting']}, {'name': 'main'}],
  ),
  TemplateInfo(
    name: 'Stacked',
    description: 'Vertical stack, document-like flow',
    numPanes: 1,
    slotNames: ['all'],
    bestFor: 'report-style documents',
    isFavorite: false,
    slots: <Map<String, dynamic>>[{'name': 'all'}],
  ),
  TemplateInfo(
    name: 'Wide-Chart',
    description: 'Chart header (60%) + inputs/tables below',
    numPanes: 3,
    slotNames: ['charts', 'inputs', 'tables'],
    bestFor: 'data visualization dashboards, complex models with many controls, chart-heavy analytics layouts',
    isFavorite: false,
    slots: <Map<String, dynamic>>[{'name': 'charts', 'preferred_usages': ['output'], 'preferred_roles': ['visualization', 'monitor'], 'preferred_kinds': ['plot']}, {'name': 'inputs', 'preferred_usages': ['input'], 'preferred_roles': ['parameter', 'setting']}, {'name': 'tables'}],
  ),
  TemplateInfo(
    name: 'Sidebar',
    description: 'Persistent input sidebar (20%) + main area',
    numPanes: 2,
    slotNames: ['sidebar', 'main'],
    bestFor: 'persistent controls with large main area',
    isFavorite: false,
    slots: <Map<String, dynamic>>[{'name': 'sidebar', 'preferred_usages': ['input'], 'preferred_roles': ['parameter', 'setting']}, {'name': 'main'}],
  ),
  TemplateInfo(
    name: 'Quad',
    description: '2x2 grid: inputs, outputs, tables, other',
    numPanes: 4,
    slotNames: ['inputs', 'outputs', 'tables', 'other'],
    bestFor: 'interactive calculators, complex models with many controls, overview dashboards, balanced multi-section dashboards',
    isFavorite: false,
    slots: <Map<String, dynamic>>[{'name': 'inputs', 'preferred_usages': ['input'], 'preferred_roles': ['parameter', 'setting']}, {'name': 'outputs', 'preferred_usages': ['output'], 'preferred_roles': ['visualization', 'monitor'], 'preferred_kinds': ['plot']}, {'name': 'tables', 'preferred_usages': ['table'], 'preferred_roles': ['data'], 'preferred_kinds': ['table']}, {'name': 'other'}],
  ),
  TemplateInfo(
    name: 'Chart',
    description: 'Plots (horizontal gutter) top + inputs below',
    numPanes: 2,
    slotNames: ['charts', 'inputs'],
    bestFor: 'data visualization dashboards',
    isFavorite: false,
    slots: <Map<String, dynamic>>[{'name': 'charts', 'preferred_usages': ['output'], 'preferred_roles': ['visualization', 'monitor'], 'preferred_kinds': ['plot']}, {'name': 'inputs'}],
  ),
];
