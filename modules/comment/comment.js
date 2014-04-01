(function($) {

$(document).ready(function() {

  $('.comment-form').submit(function() {
    var id = $(this).attr('entity:id');
    var parentId = $(this).attr('entity:parent');

    var endpoint = '/comment/save';
    if (id) {
      endpoint += '/' + id;
    }

    var entity = {
      type: 'comment',
      body: $('textarea', this).val(),
    }
    $(document).trigger('ophal:entity:save', {context: this, entity: entity});

    /* Submit data */
    $.ajax({
      type: 'POST',
      url: endpoint,
      contentType: 'application/json; charset=utf-8',
      data: JSON.stringify(entity),
      dataType: 'json',
      processData: false,
      success: function (data) {
        if (data.success) {
          /* window.location = '/comment/' + data.id; */
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

    return false;
  });
  $('.comment-form textarea').keydown(function(event) {
    if (event.keyCode == 13) {
      event.preventDefault();
      event.returnValue = false;
      $(this).closest("form").submit();
    }
  })
});

})(jQuery);