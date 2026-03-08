# Make Frontend Usable
## Delete heading after syncing DONE (at least in frontent buffer)
- Otherwise the deletion has to be synced from the todoist app during the next sync.
- Have a settings for this `emacs-todoist-on-done-action`
    - Can be one of nil, 'delete-properties 'delete-heading or a funciton that takes a maker to the heading.
    - Complement this with a `emacs-todoist-frontend-on-done-action` This overwrites the emacs-todoist-on-done-action in the frontend buffer (simply set it as a buffer local variable). 
- This happens after pushing an item that is set to DONE and after pulling a change that sets the item to DONE. 
## Automatically sync heading if todo is changed.
- I think you can use `org-after-todo-state-change-hook` to implement this.
- Perhaps we should add a minor mode for this? `emacs-todoist-mode` that enables / disables these features.
- There should probably be a setting (that is enabled by default) that toggles this behavior
## Opening emacs-todoist
- Opening emacs-todoist only rerenders the whole frame the first time. Otherwise it reuses the existing frame and syncs any changes.
## Captured TODO tasks are automatically added to the todoist buffer.
- If we capture a todoist todo it should not land in the normal todo.org buffer but only in the *Todoist* buffer. Note that it mus be sorted into the correct project.
- This might be brittle. But I want this to be the main way to add new todos. --> Also the way that is used when interacting with the *Todoist* buffer. 

# Handle items that are repeating
Currently if we mark repeating items as done from emcas they will not be rescheduled.
