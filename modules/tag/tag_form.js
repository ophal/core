(function($) {

$(document).ready(function() {
  var baseRoute = Ophal.settings.core.base.route;

  (function(context) {
  $('#save_submit', context).click(function() {
    var this_button = $(this);
    var id = $('#entity_id', context).val();
    var entity = {
      name: $('#name_field', context).val(),
      status: $('#status_field', context).is(':checked'),
      action: $('#action', context).val()
    }
    var endpoint = 'tag/service';

    if (id) {
      endpoint += '/' + id;
    }

    $(this_button).attr('disabled', 'disabled');

    $.ajax({
      type: 'POST',
      url: baseRoute + endpoint,
      contentType: 'application/json; charset=utf-8',
      data: JSON.stringify(entity),
      dataType: 'json',
      processData: false,
      success: function (data) {
        if (data.success) {
          window.location = '/tags';
        }
        else {
          $(this_button).removeAttr('disabled');
          if (data.error) {
            alert('Operation failed! Reason: ' + data.error);
          }
          else {
            alert('Operation failed!');
          }
        }
      },
      error: function() {
        $(this_button).removeAttr('disabled');
        alert('Operation error. Please try again later.');
      },
    });
  });
  })($('#tag_create_form, #tag_edit_form'));

  (function(context) {
  $('#confirm_submit', context).click(function() {
    var this_button = $(this);
    var file = {
      action: 'delete'
    }
    var endpoint = 'tag/service/' + $('#entity_id', context).val();

    $(this_button).attr('disabled', 'disabled');

    $.ajax({
      type: 'POST',
      url: baseRoute +  endpoint,
      contentType: 'application/json; charset=utf-8',
      data: JSON.stringify(file),
      dataType: 'json',
      processData: false,
      success: function (data) {
        if (data.success) {
          window.location = baseRoute + 'admin/content/tags';
        }
        else {
          $(this_button).removeAttr('disabled');
          if (data.error) {
            alert('Operation failed! Reason: ' + data.error);
          }
          else {
            alert('Operation failed!');
          }
        }
      },
      error: function() {
        $(this_button).removeAttr('disabled');
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