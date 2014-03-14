(function($) {

$(document).ready(function() {
  var form = $('#content_edit_form, #content_create_form');

  $('#save_submit', form).click(function() {
    var id = $('#content_edit_form #entity_id').val();

    var endpoint = '/content/save';
    if (id) {
      endpoint += '/' + id;
    }

    var content = {
      title: $('#content_title', form).val(),
      teaser: $('#content_teaser', form).val(),
      body: $('#content_body', form).val(),
      status: $('#content_status', form).is(':checked'),
      promote: $('#content_promote', form).is(':checked'),
    }
    $(document).trigger('ophal:entity:save', {context: form, entity: content});

    /* Fetch auth token */
    $.ajax({
      type: 'POST',
      url: endpoint,
      contentType: 'application/json; charset=utf-8',
      data: JSON.stringify(content),
      dataType: 'json',
      processData: false,
      success: function (data) {
        if (data.success) {
          window.location = '/content/' + data.id;
        }
        else {
          if (data.success) {
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
});

})(jQuery);
