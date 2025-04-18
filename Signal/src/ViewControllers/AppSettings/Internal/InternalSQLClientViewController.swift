//
// Copyright 2025 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import GRDB
import SignalServiceKit
import UIKit

class InternalSQLClientViewController: UIViewController {

    let outputTextView: UITextView = {
        let textView = UITextView()
        textView.backgroundColor = .black
        textView.textColor = .white
        textView.text = "Output will appear here"
        textView.translatesAutoresizingMaskIntoConstraints = false
        return textView
    }()

    let queryTextField: UITextField = {
        let textField = UITextField()
        textField.borderStyle = .roundedRect
        textField.placeholder = "Type your SQL query here"
        textField.translatesAutoresizingMaskIntoConstraints = false
        return textField
    }()

    lazy var runQueryButton: UIButton = {
        let button = UIButton(type: .system)
        button.setTitle("Run Query", for: .normal)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: #selector(runQuery), for: .touchUpInside)
        return button
    }()

    lazy var copyOutputButton: UIButton = {
        let button = UIButton(type: .system)
        button.setTitle("Copy Output", for: .normal)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: #selector(copyOutput), for: .touchUpInside)
        return button
    }()

    // MARK: - View Lifecycle
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .white

        view.addSubview(outputTextView)
        view.addSubview(queryTextField)
        view.addSubview(runQueryButton)
        view.addSubview(copyOutputButton)

        view.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(didTapView)))

        // Set up AutoLayout constraints
        NSLayoutConstraint.activate([
            copyOutputButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            copyOutputButton.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            copyOutputButton.heightAnchor.constraint(equalToConstant: 25),

            runQueryButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            runQueryButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            runQueryButton.heightAnchor.constraint(equalToConstant: 25),

            queryTextField.topAnchor.constraint(equalTo: runQueryButton.bottomAnchor, constant: 12),
            queryTextField.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            queryTextField.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            queryTextField.heightAnchor.constraint(equalToConstant: 40),

            outputTextView.topAnchor.constraint(equalTo: queryTextField.bottomAnchor, constant: 12),
            outputTextView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            outputTextView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            outputTextView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20),
        ])
    }

    @objc private func didTapView() {
        queryTextField.resignFirstResponder()
    }

    @objc private func runQuery() {
        queryTextField.resignFirstResponder()

        guard let query = queryTextField.text, !query.isEmpty else {
            return
        }

        let output = DependenciesBridge.shared.db.read { tx in
            do {
                return try Row
                    .fetchAll(tx.database, sql: query)
                .map({"\($0)"})
                .joined(separator: "\n")
            } catch let error {
                return "\(error)"
            }
        }

        outputTextView.text = output
    }

    @objc private func copyOutput() {
        queryTextField.resignFirstResponder()
        guard let output = outputTextView.text, !output.isEmpty else {
            return
        }
        // Copy output text to clipboard
        UIPasteboard.general.string = output

        presentToast(text: "Copied!")
    }
}
