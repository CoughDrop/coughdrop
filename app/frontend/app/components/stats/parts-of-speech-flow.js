import Component from '@ember/component';
import CoughDrop from '../../app';
import i18n from '../../utils/i18n';
import { htmlSafe } from '@ember/string';

export default Component.extend({
  didInsertElement: function() {
    this.draw();
  },
  elem_class: function() {
    if(this.get('side_by_side')) {
      return htmlSafe('col-sm-6');
    } else {
      return htmlSafe('col-sm-8');
    }
  }.property('side_by_side'),
  elem_style: function() {
    if(this.get('right_side')) {
      return htmlSafe('border-left: 1px solid #eee;');
    } else {
      return htmlSafe('');
    }
  }.property('right_side'),
  draw: function() {
    var stats = this.get('usage_stats');
    var elem = this.get('element').getElementsByClassName('parts_of_speech_combinations')[0];

    CoughDrop.Visualizations.wait('speech-flow', function() {
      if(elem && stats && stats.get('parts_of_speech_combinations')) {
        var data = new window.google.visualization.DataTable();
        data.addColumn('string', 'From');
        data.addColumn('string', 'To');
        data.addColumn('number', 'Instances');
        var rows = [];

        var combos = stats.get('parts_of_speech_combinations');
        var colors = [];
        var new_combos = {};
        for(var idx in combos) {
          var split = idx.split(',');
          var key = split[0] + ", " + split[1];
          new_combos[key] = new_combos[key] || 0;
          new_combos[key] = new_combos[key] + combos[idx];
          if(split[2]) {
            key = " " + split[0] + "," + split[1] + " ";
            new_combos[key] = new_combos[key] || 0;
            new_combos[key] = new_combos[key] + combos[idx];
          }
        }
        var split_check = function(label) {
          var type = label.replace(/^\s+/, '').replace(/\s+$/, '');
          if(!colors[label]) {
            var color = CoughDrop.keyed_colors.find(function(c) { return c.types.indexOf(type) >= 0; });
            colors.push((color || {border: "#ccc"}).border);
            colors[label] = true;
          }
        };
        for(var idx in new_combos) {
          var split = idx.split(",");
          rows.push([split[0], split[1], new_combos[idx]]);
          split.forEach(split_check);
        }
        var options = {
          sankey: {
            node: {
              colors: colors
            }
          }
        };
        data.addRows(rows);
        var chart = new window.google.visualization.Sankey(elem);
        chart.draw(data, options);
      }
    });
  }.observes('usage_stats.draw_id')
});
