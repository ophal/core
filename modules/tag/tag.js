(function($) {

$(document).ready(function() {
  (function(context) {
  $('#save_submit', context).click(function() {
    var file = {
      id: $('#tag_id', context).val(),
      name: $('#tag_name', context).val(),
      action: $('#action', context).val()
    }

    $.ajax({
      type: 'POST',
      url: '/tag/service',
      contentType: 'application/json; charset=utf-8',
      data: JSON.stringify(file),
      dataType: 'json',
      processData: false,
      success: function (data) {
        if (data.success) {
          window.location = '/tags';
        }
        else {
          if (data.error) {
            alert('Operation failed! Reason: ' + data.error);
          }
          else {
            alert('Operation failed!');
          }
        }
      },
      error: function() {
        alert('Operation error. Please try again later.');
      },
    });
  });
  })($('#tag_save_form'));

  (function(context) {
  $('#confirm_submit', context).click(function() {
    var file = {
      id: $('#tag_id', context).val(),
      action: 'delete'
    }

    $.ajax({
      type: 'POST',
      url: '/tag/service',
      contentType: 'application/json; charset=utf-8',
      data: JSON.stringify(file),
      dataType: 'json',
      processData: false,
      success: function (data) {
        if (data.success) {
          window.location = '/tags';
        }
        else {
          if (data.error) {
            alert('Operation failed! Reason: ' + data.error);
          }
          else {
            alert('Operation failed!');
          }
        }
      },
      error: function() {
        alert('Operation error. Please try again later.');
      },
    });
  });
  })($('#tag_delete_form'));

  $(document).bind('ophal:entity:save', function(caller, variables) {
    var context = variables.context
    var entity = variables.entity

    entity.tags = $('#field_tags', context).val();
  });
});

})(jQuery);