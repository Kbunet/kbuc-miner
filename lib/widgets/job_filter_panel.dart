import 'package:flutter/material.dart';
import '../services/mining_job_service.dart';

class JobFilterPanel extends StatefulWidget {
  final Function(Map<String, dynamic>) onFilterChanged;
  final Map<String, dynamic> filterOptions;
  final Map<String, dynamic> currentFilters;

  const JobFilterPanel({
    Key? key,
    required this.onFilterChanged,
    required this.filterOptions,
    required this.currentFilters,
  }) : super(key: key);

  @override
  State<JobFilterPanel> createState() => _JobFilterPanelState();
}

class _JobFilterPanelState extends State<JobFilterPanel> {
  late Map<String, dynamic> _currentFilters;
  bool _isExpanded = false;
  RangeValues? _difficultyRange;

  @override
  void initState() {
    super.initState();
    _currentFilters = Map.from(widget.currentFilters);
    
    // Initialize difficulty range if available
    if (widget.filterOptions['difficulties'] != null && 
        widget.filterOptions['difficulties'].isNotEmpty) {
      final List<int> difficulties = List<int>.from(widget.filterOptions['difficulties']);
      difficulties.sort();
      
      final double minDifficulty = difficulties.first.toDouble();
      final double maxDifficulty = difficulties.last.toDouble();
      
      // Initialize with current filter values or defaults
      final List<int>? currentRange = _currentFilters['difficultyRange'];
      if (currentRange != null && currentRange.length == 2) {
        _difficultyRange = RangeValues(
          currentRange[0].toDouble(), 
          currentRange[1].toDouble()
        );
      } else {
        _difficultyRange = RangeValues(minDifficulty, maxDifficulty);
        _currentFilters['difficultyRange'] = [minDifficulty.toInt(), maxDifficulty.toInt()];
      }
    }
  }

  void _applyFilters() {
    widget.onFilterChanged(_currentFilters);
  }

  void _resetFilters() {
    setState(() {
      _currentFilters = {
        'sortBy': JobSortOption.creationTimeDesc,
        'statusFilter': JobStatusFilter.all,
      };
      
      // Reset difficulty range if available
      if (widget.filterOptions['difficulties'] != null && 
          widget.filterOptions['difficulties'].isNotEmpty) {
        final List<int> difficulties = List<int>.from(widget.filterOptions['difficulties']);
        difficulties.sort();
        
        final double minDifficulty = difficulties.first.toDouble();
        final double maxDifficulty = difficulties.last.toDouble();
        
        _difficultyRange = RangeValues(minDifficulty, maxDifficulty);
        _currentFilters['difficultyRange'] = [minDifficulty.toInt(), maxDifficulty.toInt()];
      } else {
        _currentFilters.remove('difficultyRange');
      }
      
      // Clear other filters
      _currentFilters.remove('owner');
      _currentFilters.remove('leader');
      _currentFilters.remove('height');
      _currentFilters.remove('content');
    });
    
    _applyFilters();
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.all(8.0),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Header with expand/collapse button
          ListTile(
            title: const Text('Filter & Sort Jobs'),
            trailing: IconButton(
              icon: Icon(_isExpanded ? Icons.expand_less : Icons.expand_more),
              onPressed: () {
                setState(() {
                  _isExpanded = !_isExpanded;
                });
              },
            ),
          ),
          
          // Expandable filter content
          if (_isExpanded)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Sort options
                  const Text('Sort by:', style: TextStyle(fontWeight: FontWeight.bold)),
                  DropdownButton<JobSortOption>(
                    isExpanded: true,
                    value: _currentFilters['sortBy'] as JobSortOption,
                    items: JobSortOption.values.map((option) {
                      String label;
                      switch (option) {
                        case JobSortOption.creationTimeDesc:
                          label = 'Creation Time (Newest First)';
                          break;
                        case JobSortOption.creationTimeAsc:
                          label = 'Creation Time (Oldest First)';
                          break;
                        case JobSortOption.difficultyDesc:
                          label = 'Difficulty (Highest First)';
                          break;
                        case JobSortOption.difficultyAsc:
                          label = 'Difficulty (Lowest First)';
                          break;
                      }
                      return DropdownMenuItem<JobSortOption>(
                        value: option,
                        child: Text(label),
                      );
                    }).toList(),
                    onChanged: (value) {
                      if (value != null) {
                        setState(() {
                          _currentFilters['sortBy'] = value;
                        });
                        _applyFilters();
                      }
                    },
                  ),
                  
                  const SizedBox(height: 16),
                  
                  // Status filter
                  const Text('Status:', style: TextStyle(fontWeight: FontWeight.bold)),
                  DropdownButton<JobStatusFilter>(
                    isExpanded: true,
                    value: _currentFilters['statusFilter'] as JobStatusFilter,
                    items: JobStatusFilter.values.map((status) {
                      String label;
                      switch (status) {
                        case JobStatusFilter.all:
                          label = 'All Jobs';
                          break;
                        case JobStatusFilter.active:
                          label = 'Active Jobs';
                          break;
                        case JobStatusFilter.completed:
                          label = 'Completed Jobs';
                          break;
                        case JobStatusFilter.successful:
                          label = 'Successful Jobs';
                          break;
                        case JobStatusFilter.failed:
                          label = 'Failed Jobs';
                          break;
                      }
                      return DropdownMenuItem<JobStatusFilter>(
                        value: status,
                        child: Text(label),
                      );
                    }).toList(),
                    onChanged: (value) {
                      if (value != null) {
                        setState(() {
                          _currentFilters['statusFilter'] = value;
                        });
                        _applyFilters();
                      }
                    },
                  ),
                  
                  const SizedBox(height: 16),
                  
                  // Difficulty range slider
                  if (_difficultyRange != null && widget.filterOptions['difficulties'] != null) ...[
                    const Text('Difficulty Range:', style: TextStyle(fontWeight: FontWeight.bold)),
                    RangeSlider(
                      values: _difficultyRange!,
                      min: widget.filterOptions['difficulties'].first.toDouble(),
                      max: widget.filterOptions['difficulties'].last.toDouble(),
                      divisions: widget.filterOptions['difficulties'].length > 1 
                          ? widget.filterOptions['difficulties'].length - 1 
                          : 1,
                      labels: RangeLabels(
                        _difficultyRange!.start.round().toString(),
                        _difficultyRange!.end.round().toString(),
                      ),
                      onChanged: (values) {
                        setState(() {
                          _difficultyRange = values;
                          _currentFilters['difficultyRange'] = [
                            values.start.round(),
                            values.end.round(),
                          ];
                        });
                      },
                      onChangeEnd: (values) {
                        _applyFilters();
                      },
                    ),
                    
                    const SizedBox(height: 16),
                  ],
                  
                  // Owner filter
                  if (widget.filterOptions['owners'] != null && widget.filterOptions['owners'].isNotEmpty) ...[
                    const Text('Owner:', style: TextStyle(fontWeight: FontWeight.bold)),
                    DropdownButton<String>(
                      isExpanded: true,
                      value: _currentFilters['owner'],
                      items: [
                        const DropdownMenuItem<String>(
                          value: null,
                          child: Text('All Owners'),
                        ),
                        ...widget.filterOptions['owners'].map<DropdownMenuItem<String>>((owner) {
                          return DropdownMenuItem<String>(
                            value: owner,
                            child: Text(owner),
                          );
                        }).toList(),
                      ],
                      onChanged: (value) {
                        setState(() {
                          if (value == null) {
                            _currentFilters.remove('owner');
                          } else {
                            _currentFilters['owner'] = value;
                          }
                        });
                        _applyFilters();
                      },
                    ),
                    
                    const SizedBox(height: 16),
                  ],
                  
                  // Leader filter
                  if (widget.filterOptions['leaders'] != null && widget.filterOptions['leaders'].isNotEmpty) ...[
                    const Text('Leader:', style: TextStyle(fontWeight: FontWeight.bold)),
                    DropdownButton<String>(
                      isExpanded: true,
                      value: _currentFilters['leader'],
                      items: [
                        const DropdownMenuItem<String>(
                          value: null,
                          child: Text('All Leaders'),
                        ),
                        ...widget.filterOptions['leaders'].map<DropdownMenuItem<String>>((leader) {
                          return DropdownMenuItem<String>(
                            value: leader,
                            child: Text(leader),
                          );
                        }).toList(),
                      ],
                      onChanged: (value) {
                        setState(() {
                          if (value == null) {
                            _currentFilters.remove('leader');
                          } else {
                            _currentFilters['leader'] = value;
                          }
                        });
                        _applyFilters();
                      },
                    ),
                    
                    const SizedBox(height: 16),
                  ],
                  
                  // Height filter
                  if (widget.filterOptions['heights'] != null && widget.filterOptions['heights'].isNotEmpty) ...[
                    const Text('Height:', style: TextStyle(fontWeight: FontWeight.bold)),
                    DropdownButton<int>(
                      isExpanded: true,
                      value: _currentFilters['height'],
                      items: [
                        const DropdownMenuItem<int>(
                          value: null,
                          child: Text('All Heights'),
                        ),
                        ...widget.filterOptions['heights'].map<DropdownMenuItem<int>>((height) {
                          return DropdownMenuItem<int>(
                            value: height,
                            child: Text(height.toString()),
                          );
                        }).toList(),
                      ],
                      onChanged: (value) {
                        setState(() {
                          if (value == null) {
                            _currentFilters.remove('height');
                          } else {
                            _currentFilters['height'] = value;
                          }
                        });
                        _applyFilters();
                      },
                    ),
                    
                    const SizedBox(height: 16),
                  ],
                  
                  // Content search
                  const Text('Content Search:', style: TextStyle(fontWeight: FontWeight.bold)),
                  TextField(
                    decoration: const InputDecoration(
                      hintText: 'Search in content...',
                      prefixIcon: Icon(Icons.search),
                    ),
                    onChanged: (value) {
                      setState(() {
                        if (value.isEmpty) {
                          _currentFilters.remove('content');
                        } else {
                          _currentFilters['content'] = value;
                        }
                      });
                      // Debounce search to avoid too many filter operations
                      Future.delayed(const Duration(milliseconds: 500), () {
                        _applyFilters();
                      });
                    },
                  ),
                  
                  const SizedBox(height: 16),
                  
                  // Reset filters button
                  Center(
                    child: ElevatedButton.icon(
                      icon: const Icon(Icons.refresh),
                      label: const Text('Reset Filters'),
                      onPressed: _resetFilters,
                    ),
                  ),
                  
                  const SizedBox(height: 16),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
