//
// Copyright 2018 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import ContactsUI
import SignalServiceKit
import SignalUI

class AddContactShareToExistingContactViewController: ContactPickerViewController {

    // TODO - there are some hard coded assumptions in this VC that assume we are *pushed* onto a
    // navigation controller. That seems fine for now, but if we need to be presented as a modal,
    // or need to notify our presenter about our dismisall or other contact actions, a delegate
    // would be helpful. It seems like this would require some broad changes to the ContactShareViewHelper,
    // so I've left it as is for now, since it happens to work.
    // weak var addToExistingContactDelegate: AddContactShareToExistingContactViewControllerDelegate?

    let contactShare: ContactShareViewModel

    required init(contactShare: ContactShareViewModel) {
        self.contactShare = contactShare

        super.init(allowsMultipleSelection: false, subtitleCellType: .none)

        delegate = self
    }

    required public init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    required public init(allowsMultipleSelection: Bool, subtitleCellType: SubtitleCellValue) {
        fatalError("init(allowsMultipleSelection:subtitleCellType:) has not been implemented")
    }

    func merge(oldCNContact: CNContact, newCNContact: CNContact) {
        Logger.debug("")

        let mergedCNContact: CNContact = Contact.merge(cnContact: oldCNContact, newCNContact: newCNContact)

        // Not actually a "new" contact, but this brings up the edit form rather than the "Read" form
        // saving our users a tap in some cases when we already know they want to edit.
        let contactViewController: CNContactViewController = CNContactViewController(forNewContact: mergedCNContact)

        // Default title is "New Contact". We could give a more descriptive title, but anything
        // seems redundant - the context is sufficiently clear.
        contactViewController.title = ""
        contactViewController.allowsActions = false
        contactViewController.allowsEditing = true
        contactViewController.delegate = self

        let modal = OWSNavigationController(rootViewController: contactViewController)
        present(modal, animated: true)
    }
}

extension AddContactShareToExistingContactViewController: ContactPickerDelegate {

    func contactPickerDidCancel(_: ContactPickerViewController) {
        Logger.debug("")

        guard let navigationController else {
            owsFailDebug("navigationController was unexpectedly nil")
            return
        }

        navigationController.popViewController(animated: true)
    }

    func contactPicker(_: ContactPickerViewController, didSelect oldContact: Contact) {
        Logger.debug("")

        guard let cnContactId = oldContact.cnContactId,
              let oldCNContact = contactsManager.cnContact(withId: cnContactId) else {
            owsFailDebug("could not load old CNContact.")
            return
        }
        guard let newCNContact = OWSContacts.systemContact(for: contactShare.dbRecord, imageData: contactShare.avatarImageData) else {
            owsFailDebug("could not load new CNContact.")
            return
        }
        merge(oldCNContact: oldCNContact, newCNContact: newCNContact)
    }

    func contactPicker(_: ContactPickerViewController, didSelectMultiple contacts: [Contact]) {
        Logger.debug("")
        owsFailDebug("only supports single contact select")

        guard let navigationController else {
            owsFailDebug("navigationController was unexpectedly nil")
            return
        }

        navigationController.popViewController(animated: true)
    }

    func contactPicker(_: ContactPickerViewController, shouldSelect contact: Contact) -> Bool {
        return true
    }
}

extension AddContactShareToExistingContactViewController: CNContactViewControllerDelegate {

    func contactViewController(_ viewController: CNContactViewController, didCompleteWith contact: CNContact?) {
        Logger.debug("")

        guard let navigationController else {
            owsFailDebug("navigationController was unexpectedly nil")
            return
        }

        // TODO this is weird - ideally we'd do something like
        //     self.delegate?.didFinishAddingContact
        // and the delegate, which knows about our presentation context could do the right thing.
        //
        // As it is, we happen to always be *pushing* this view controller onto a navcontroller, so the
        // following works in all current cases.
        //
        // If we ever wanted to do something different, like present this in a modal, we'd have to rethink.

        // We want to pop *this* view *and* the still presented CNContactViewController in a single animation.
        // Note this happens for *cancel* and for *done*. Unfortunately, I don't know of a way to detect the difference
        // between the two, since both just call this method.
        guard let myIndex = navigationController.viewControllers.firstIndex(of: self) else {
            owsFailDebug("myIndex was unexpectedly nil")
            navigationController.popViewController(animated: true)
            navigationController.popViewController(animated: true)
            return
        }

        let previousViewControllerIndex = navigationController.viewControllers.index(before: myIndex)
        let previousViewController = navigationController.viewControllers[previousViewControllerIndex]

        dismiss(animated: false) {
            navigationController.popToViewController(previousViewController, animated: true)
        }
    }
}
