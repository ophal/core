Ophal.extend('comment', function ($) {

function load_comments() {
  var content = Ophal.settings.content.current;
  var core = Ophal.settings.core;

  /* Fetch current content comments */
  $.ajax({
    type: 'GET',
    url: core.base.route + 'comment/fetch/' + content.id,
    contentType: 'application/json; charset=utf-8',
    processData: false,
    success: function (data) {
      if (data.success) {
        var wrapper = $('<div class="comments-wrapper"></div>');
        for (k in data.list) {
          $(wrapper).prepend(data.list[k].rendered);
        }
        $('#content').append(wrapper);
        Ophal.scroll_down();
      }
      else {
        Ophal.set_message('Comments not available.');
      }
    },
    error: function() {
      Ophal.set_message('Error loading comments.');
    },
  });
}

$(document).ready(function() {
  /* Load comments if current page is an entity */
  if (Ophal.settings.content) {
    load_comments();
  }

  $('.comment-form').submit(function() {
    var id = $(this).attr('entity:id');
    var entityId = $(this).attr('entity:entity_id');
    var parentId = $(this).attr('entity:parent_id');

    var endpoint = '/comment/save';
    if (id) {
      endpoint += '/' + id;
    }

    var entity = {
      type: 'comment',
      entity_id: entityId,
      parent_id: parentId,
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
          window.location = data.return_path + '#comment-' + data.id;
        }
        else {
          $(this).removeAttr('disabled');
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

    return false;
  });
  $('.comment-form textarea').keydown(function(event) {
    if (event.keyCode == 13) {
      $(this).attr('disabled', 'disabled');
      event.preventDefault();
      event.returnValue = false;
      $(this).closest("form").submit();
    }
  })
});

});
