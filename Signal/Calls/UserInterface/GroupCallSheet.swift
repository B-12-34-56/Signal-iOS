//
// Copyright 2020 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import LibSignalClient
import SignalRingRTC
import SignalServiceKit
import SignalUI
import Combine

// MARK: - GroupCallSheet

class GroupCallSheet: InteractiveSheetViewController {
    private let callControls: CallControls

    // MARK: Properties

    override var interactiveScrollViews: [UIScrollView] { [tableView] }
    override var canBeDismissed: Bool {
        return false
    }
    override var canInteractWithParent: Bool {
        return true
    }

    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let call: SignalCall
    private let ringRtcCall: SignalRingRTC.GroupCall
    private let groupThreadCall: GroupThreadCall

    private var tableViewTopConstraint: NSLayoutConstraint?

    override var sheetBackgroundColor: UIColor {
        self.tableView.backgroundColor ?? .systemGroupedBackground
    }

    init(
        call: SignalCall,
        groupThreadCall: GroupThreadCall,
        callService: CallService,
        confirmationToastManager: CallControlsConfirmationToastManager,
        callControlsDelegate: CallControlsDelegate
    ) {
        self.call = call
        self.ringRtcCall = groupThreadCall.ringRtcCall
        self.groupThreadCall = groupThreadCall
        self.callControls = CallControls(
            call: call,
            callService: callService,
            confirmationToastManager: confirmationToastManager,
            delegate: callControlsDelegate
        )

        super.init(blurEffect: nil)

        self.overrideUserInterfaceStyle = .dark
        groupThreadCall.addObserver(self, syncStateImmediately: true)

        callControls.addHeightObserver(self)
        self.tableView.alpha = 0
        // Don't add a dim visual effect to the call when the sheet is open.
        self.backdropColor = .clear
    }

    override func maximumAllowedHeight() -> CGFloat {
        guard let windowHeight = view.window?.frame.height else {
            return super.maximumAllowedHeight()
        }
        let halfHeight = windowHeight / 2
        let twoThirdsHeight = 2 * windowHeight / 3
        let tableHeight = tableView.contentSize.height
        if tableHeight >= twoThirdsHeight {
            return twoThirdsHeight
        } else if tableHeight > halfHeight {
            return tableHeight
        } else {
            return halfHeight
        }
    }

    // MARK: - Table setup

    private typealias DiffableDataSource = UITableViewDiffableDataSource<Section, RowID>
    private typealias Snapshot = NSDiffableDataSourceSnapshot<Section, RowID>

    private enum Section: Hashable {
        case raisedHands
        case inCall
    }

    private struct RowID: Hashable {
        var section: Section
        var memberID: JoinedMember.ID
    }

    private lazy var dataSource = DiffableDataSource(
        tableView: tableView
    ) { [weak self] tableView, indexPath, id -> UITableViewCell? in
        guard let cell = tableView.dequeueReusableCell(GroupCallMemberCell.self, for: indexPath) else { return nil }

        cell.ringRtcCall = self?.ringRtcCall

        guard let viewModel = self?.viewModelsByID[id.memberID] else {
            owsFailDebug("missing view model")
            return cell
        }

        cell.configure(with: viewModel, isHandRaised: id.section == .raisedHands)

        return cell
    }

    private class HeaderView: UIView {
        private let section: Section
        var memberCount: Int = 0 {
            didSet {
                self.updateText()
            }
        }

        private let label = UILabel()

        init(section: Section) {
            self.section = section
            super.init(frame: .zero)

            self.addSubview(self.label)
            self.label.autoPinEdgesToSuperviewMargins()
            self.updateText()
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        private func updateText() {
            let titleText: String = switch section {
            case .raisedHands:
                OWSLocalizedString(
                    "GROUP_CALL_MEMBER_LIST_RAISED_HANDS_SECTION_HEADER",
                    comment: "Title for the section of the group call member list which displays the list of members with their hand raised."
                )
            case .inCall:
                OWSLocalizedString(
                    "GROUP_CALL_MEMBER_LIST_IN_CALL_SECTION_HEADER",
                    comment: "Title for the section of the group call member list which displays the list of all members in the call."
                )
            }

            label.attributedText = .composed(of: [
                titleText.styled(with: .font(.dynamicTypeHeadline)),
                " ",
                String(
                    format: OWSLocalizedString(
                        "GROUP_CALL_MEMBER_LIST_SECTION_HEADER_MEMBER_COUNT",
                        comment: "A count of members in a given group call member list section, displayed after the header."
                    ),
                    self.memberCount
                )
            ]).styled(
                with: .font(.dynamicTypeBody),
                .color(Theme.darkThemePrimaryColor)
            )
        }
    }

    private let raisedHandsHeader = HeaderView(section: .raisedHands)
    private let inCallHeader = HeaderView(section: .inCall)

    func setBottomSheetMinimizedHeight() {
        minimizedHeight = callControls.currentHeight + HeightConstants.bottomPadding
    }

    override public func viewDidLoad() {
        super.viewDidLoad()

        tableView.delegate = self
        tableView.tableHeaderView = UIView(frame: CGRect(origin: .zero, size: CGSize(width: 0, height: CGFloat.leastNormalMagnitude)))
        contentView.addSubview(tableView)
        tableViewTopConstraint = tableView.autoPinEdge(toSuperviewEdge: .top, withInset: HeightConstants.initialTableInset)
        tableView.autoPinEdge(toSuperviewEdge: .bottom)
        tableView.autoPinEdge(toSuperviewEdge: .leading)
        tableView.autoPinEdge(toSuperviewEdge: .trailing)

        tableView.register(GroupCallMemberCell.self, forCellReuseIdentifier: GroupCallMemberCell.reuseIdentifier)

        tableView.dataSource = self.dataSource

        callControls.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(callControls)
        NSLayoutConstraint.activate([
            callControls.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            callControls.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10)
        ])

        updateMembers()
    }

    // MARK: - Table contents

    fileprivate struct JoinedMember {
        enum ID: Hashable {
            case aci(Aci)
            case demuxID(DemuxId)
        }

        let id: ID

        let aci: Aci
        let displayName: String
        let comparableName: DisplayName.ComparableValue
        let demuxID: DemuxId?
        let isLocalUser: Bool
        let isAudioMuted: Bool?
        let isVideoMuted: Bool?
        let isPresenting: Bool?
    }

    private var viewModelsByID: [JoinedMember.ID: GroupCallMemberCell.ViewModel] = [:]
    private var sortedMembers = [JoinedMember]() {
        didSet {
            let oldMemberIDs = viewModelsByID.keys
            let newMemberIDs = sortedMembers.map(\.id)
            let viewModelsToRemove = Set(oldMemberIDs).subtracting(newMemberIDs)
            viewModelsToRemove.forEach { viewModelsByID.removeValue(forKey: $0) }

            viewModelsByID = sortedMembers.reduce(into: viewModelsByID) { partialResult, member in
                if let existingViewModel = partialResult[member.id] {
                    existingViewModel.update(using: member)
                } else {
                    partialResult[member.id] = .init(member: member)
                }
            }
        }
    }

    private func updateMembers() {
        let unsortedMembers: [JoinedMember] = databaseStorage.read { transaction -> [JoinedMember] in
            let tsAccountManager = DependenciesBridge.shared.tsAccountManager
            guard let localIdentifiers = tsAccountManager.localIdentifiers(tx: transaction.asV2Read) else {
                return []
            }

            var members = [JoinedMember]()
            let config: DisplayName.ComparableValue.Config = .current()
            if self.ringRtcCall.localDeviceState.joinState == .joined {
                members += self.ringRtcCall.remoteDeviceStates.values.map { member in
                    let resolvedName: String
                    let comparableName: DisplayName.ComparableValue
                    if member.aci == localIdentifiers.aci {
                        resolvedName = OWSLocalizedString(
                            "GROUP_CALL_YOU_ON_ANOTHER_DEVICE",
                            comment: "Text describing the local user in the group call members sheet when connected from another device."
                        )
                        comparableName = .nameValue(resolvedName)
                    } else {
                        let displayName = self.contactsManager.displayName(for: member.address, tx: transaction)
                        resolvedName = displayName.resolvedValue(config: config.displayNameConfig)
                        comparableName = displayName.comparableValue(config: config)
                    }

                    return JoinedMember(
                        id: .demuxID(member.demuxId),
                        aci: member.aci,
                        displayName: resolvedName,
                        comparableName: comparableName,
                        demuxID: member.demuxId,
                        isLocalUser: false,
                        isAudioMuted: member.audioMuted,
                        isVideoMuted: member.videoMuted,
                        isPresenting: member.presenting
                    )
                }

                let displayName = CommonStrings.you
                let comparableName: DisplayName.ComparableValue = .nameValue(displayName)
                let id: JoinedMember.ID
                let demuxId: UInt32?
                if let localDemuxId = groupThreadCall.ringRtcCall.localDeviceState.demuxId {
                    id = .demuxID(localDemuxId)
                    demuxId = localDemuxId
                } else {
                    id = .aci(localIdentifiers.aci)
                    demuxId = nil
                }
                members.append(JoinedMember(
                    id: id,
                    aci: localIdentifiers.aci,
                    displayName: displayName,
                    comparableName: comparableName,
                    demuxID: demuxId,
                    isLocalUser: true,
                    isAudioMuted: self.ringRtcCall.isOutgoingAudioMuted,
                    isVideoMuted: self.ringRtcCall.isOutgoingVideoMuted,
                    isPresenting: false
                ))
            } else {
                // If we're not yet in the call, `remoteDeviceStates` will not exist.
                // We can get the list of joined members still, provided we are connected.
                members += self.ringRtcCall.peekInfo?.joinedMembers.map { aciUuid in
                    let aci = Aci(fromUUID: aciUuid)
                    let address = SignalServiceAddress(aci)
                    let displayName = self.contactsManager.displayName(for: address, tx: transaction)
                    return JoinedMember(
                        id: .aci(aci),
                        aci: aci,
                        displayName: displayName.resolvedValue(config: config.displayNameConfig),
                        comparableName: displayName.comparableValue(config: config),
                        demuxID: nil,
                        isLocalUser: false,
                        isAudioMuted: nil,
                        isVideoMuted: nil,
                        isPresenting: nil
                    )
                } ?? []
            }

            return members
        }

        sortedMembers = unsortedMembers.sorted {
            let nameComparison = $0.comparableName.isLessThanOrNilIfEqual($1.comparableName)
            if let nameComparison {
                return nameComparison
            }
            if $0.aci != $1.aci {
                return $0.aci < $1.aci
            }
            return $0.demuxID ?? 0 < $1.demuxID ?? 0
        }

        self.updateSnapshotAndHeaders()
    }

    private func updateSnapshotAndHeaders() {
        var snapshot = Snapshot()

        if !groupThreadCall.raisedHands.isEmpty {
            snapshot.appendSections([.raisedHands])
            snapshot.appendItems(
                groupThreadCall.raisedHands.map {
                    RowID(section: .raisedHands, memberID: .demuxID($0))
                },
                toSection: .raisedHands
            )

            raisedHandsHeader.memberCount = groupThreadCall.raisedHands.count
        }

        snapshot.appendSections([.inCall])
        snapshot.appendItems(
            sortedMembers.map { RowID(section: .inCall, memberID: $0.id) },
            toSection: .inCall
        )

        inCallHeader.memberCount = sortedMembers.count

        dataSource.apply(snapshot, animatingDifferences: true) { [weak self] in
            self?.refreshMaxHeight()
        }
    }

    private func changesForSnapToMax() {
        self.tableView.alpha = 1
        self.callControls.alpha = 0
        self.tableViewTopConstraint?.constant = 0
        self.view.layoutIfNeeded()
    }

    private func changesForSnapToMin() {
        self.tableView.alpha = 0
        self.callControls.alpha = 1
        self.tableViewTopConstraint?.constant = HeightConstants.initialTableInset
        self.view.layoutIfNeeded()
    }

    override func heightDidChange(to height: InteractiveSheetViewController.SheetHeight) {
        switch height {
        case .min:
            changesForSnapToMin()
        case .height(let height):
            let distance = self.maxHeight - self.minimizedHeight

            // The "pivot point" is the sheet height where call controls have totally
            // faded out and the call info table begins to fade in.
            let pivotPoint = minimizedHeight + 0.1*distance

            if height <= self.minimizedHeight {
                changesForSnapToMin()
            } else if height > self.minimizedHeight && height < pivotPoint {
                tableView.alpha = 0
                let denominator = pivotPoint - self.minimizedHeight
                if denominator <= 0 {
                    owsFailBeta("You've changed the conditions of this if-branch such that the denominator could be zero!")
                    callControls.alpha = 1
                } else {
                    callControls.alpha = 1 - ((height - self.minimizedHeight) / denominator)
                }
            } else if height >= pivotPoint && height < maxHeight {
                callControls.alpha = 0

                // Table view fades in as sheet opens and fades out as sheet closes.
                let denominator = maxHeight - pivotPoint
                if denominator <= 0 {
                    owsFailBeta("You've changed the conditions of this if-branch such that the denominator could be zero!")
                    tableView.alpha = 0
                } else {
                    tableView.alpha = (height - pivotPoint) / denominator
                }

                // Table view slides up via a y-shift to its final position as the sheet opens.

                // The distance across which the y-shift will be completed.
                let totalTravelableDistanceForSheet = maxHeight - pivotPoint
                // The distance traveled in the y-shift range.
                let distanceTraveledBySheetSoFar = height - pivotPoint
                // Table travel distance per unit sheet travel distance.
                let stepSize = HeightConstants.initialTableInset / totalTravelableDistanceForSheet
                // How far the table should have traveled.
                let tableTravelDistance = stepSize * distanceTraveledBySheetSoFar
                self.tableViewTopConstraint?.constant = HeightConstants.initialTableInset - tableTravelDistance
            } else if height == maxHeight {
                changesForSnapToMax()
            } else {
                owsFailDebug("GroupCallSheet is somehow taller than its maxHeight!")
            }
        case .max:
            changesForSnapToMax()
        }
    }
}

// MARK: UITableViewDelegate

extension GroupCallSheet: UITableViewDelegate {
    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        if section == 0, !groupThreadCall.raisedHands.isEmpty {
            return raisedHandsHeader
        } else {
            return inCallHeader
        }
    }

    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        return UITableView.automaticDimension
    }

    func tableView(_ tableView: UITableView, heightForFooterInSection section: Int) -> CGFloat {
        return .leastNormalMagnitude
    }
}

// MARK: CallObserver

extension GroupCallSheet: GroupCallObserver {
    func groupCallLocalDeviceStateChanged(_ call: GroupCall) {
        AssertIsOnMainThread()
        updateMembers()
    }

    func groupCallRemoteDeviceStatesChanged(_ call: GroupCall) {
        AssertIsOnMainThread()
        updateMembers()
    }

    func groupCallPeekChanged(_ call: GroupCall) {
        AssertIsOnMainThread()
        updateMembers()
    }

    func groupCallEnded(_ call: GroupCall, reason: GroupCallEndReason) {
        AssertIsOnMainThread()
        updateMembers()
    }

    func groupCallReceivedRaisedHands(_ call: GroupCall, raisedHands: [DemuxId]) {
        AssertIsOnMainThread()
        updateSnapshotAndHeaders()
    }
}

extension GroupCallSheet: EmojiPickerSheetPresenter {
    func present(sheet: EmojiPickerSheet, animated: Bool) {
        self.present(sheet, animated: animated)
    }
}

extension GroupCallSheet {
    func isPresentingCallControls() -> Bool {
        return self.presentingViewController != nil && callControls.alpha == 1
    }

    func isPresentingCallInfo() -> Bool {
        return self.presentingViewController != nil && tableView.alpha == 1
    }

    func isCrossFading() -> Bool {
        return self.presentingViewController != nil && callControls.alpha < 1 && tableView.alpha < 1
    }
}

// MARK: - GroupCallMemberCell

private class GroupCallMemberCell: UITableViewCell, ReusableTableViewCell {

    // MARK: ViewModel

    class ViewModel {
        typealias Member = GroupCallSheet.JoinedMember

        let aci: Aci
        let name: String
        let isLocalUser: Bool

        @Published var shouldShowAudioMutedIcon = false
        @Published var shouldShowVideoMutedIcon = false
        @Published var shouldShowPresentingIcon = false

        init(member: Member) {
            self.aci = member.aci
            self.name = member.displayName
            self.isLocalUser = member.isLocalUser
            self.update(using: member)
        }

        func update(using member: Member) {
            owsAssertDebug(aci == member.aci)
            self.shouldShowAudioMutedIcon = member.isAudioMuted ?? false
            self.shouldShowVideoMutedIcon = member.isVideoMuted == true && member.isPresenting != true
            self.shouldShowPresentingIcon = member.isPresenting ?? false
        }
    }

    // MARK: Properties

    static let reuseIdentifier = "GroupCallMemberCell"

    var ringRtcCall: SignalRingRTC.GroupCall?

    private let avatarView = ConversationAvatarView(
        sizeClass: .thirtySix,
        localUserDisplayMode: .asUser,
        badged: false
    )

    private let nameLabel = UILabel()

    private lazy var lowerHandButton = OWSButton(
        title: CallStrings.lowerHandButton,
        tintColor: .ows_white,
        dimsWhenHighlighted: true
    ) { [weak self] in
        self?.ringRtcCall?.raiseHand(raise: false)
    }

    private let leadingWrapper = UIView()
    private let videoMutedIndicator = UIImageView()
    private let presentingIndicator = UIImageView()

    private let audioMutedIndicator = UIImageView()
    private let raisedHandIndicator = UIImageView()

    private var subscriptions = Set<AnyCancellable>()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)

        selectionStyle = .none

        nameLabel.textColor = Theme.darkThemePrimaryColor
        nameLabel.font = .dynamicTypeBody

        lowerHandButton.titleLabel?.font = .dynamicTypeBody

        func setup(iconView: UIImageView, withImageNamed imageName: String, in wrapper: UIView) {
            iconView.setTemplateImageName(imageName, tintColor: Theme.darkThemeSecondaryTextAndIconColor)
            wrapper.addSubview(iconView)
            iconView.autoPinEdgesToSuperviewEdges()
        }

        let trailingWrapper = UIView()
        setup(iconView: audioMutedIndicator, withImageNamed: "mic-slash", in: trailingWrapper)
        setup(iconView: raisedHandIndicator, withImageNamed: Theme.iconName(.raiseHand), in: trailingWrapper)

        setup(iconView: videoMutedIndicator, withImageNamed: "video-slash", in: leadingWrapper)
        setup(iconView: presentingIndicator, withImageNamed: "share_screen", in: leadingWrapper)

        let stackView = UIStackView(arrangedSubviews: [
            avatarView,
            nameLabel,
            lowerHandButton,
            leadingWrapper,
            trailingWrapper
        ])
        stackView.axis = .horizontal
        stackView.alignment = .center
        contentView.addSubview(stackView)
        stackView.autoPinEdgesToSuperviewMargins()

        stackView.spacing = 16
        stackView.setCustomSpacing(12, after: avatarView)
        stackView.setCustomSpacing(8, after: nameLabel)
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: Configuration

    // isHandRaised isn't part of ViewModel because the same view model is used
    // for any given member in both the members and raised hand sections.
    func configure(with viewModel: ViewModel, isHandRaised: Bool) {
        self.subscriptions.removeAll()

        if isHandRaised {
            self.raisedHandIndicator.isHidden = false
            self.lowerHandButton.isHiddenInStackView = !viewModel.isLocalUser
            self.audioMutedIndicator.isHidden = true
            self.leadingWrapper.isHiddenInStackView = true
        } else {
            self.raisedHandIndicator.isHidden = true
            self.lowerHandButton.isHiddenInStackView = true
            self.leadingWrapper.isHiddenInStackView = false
            self.subscribe(to: viewModel.$shouldShowAudioMutedIcon, showing: self.audioMutedIndicator)
            self.subscribe(to: viewModel.$shouldShowVideoMutedIcon, showing: self.videoMutedIndicator)
            self.subscribe(to: viewModel.$shouldShowPresentingIcon, showing: self.presentingIndicator)
        }

        self.nameLabel.text = viewModel.name
        self.avatarView.updateWithSneakyTransactionIfNecessary { config in
            config.dataSource = .address(SignalServiceAddress(viewModel.aci))
        }
    }

    private func subscribe(to publisher: Published<Bool>.Publisher, showing view: UIView) {
        publisher
            .removeDuplicates()
            .sink { [weak view] shouldShow in
                view?.isHidden = !shouldShow
            }
            .store(in: &self.subscriptions)
    }

}

extension GroupCallSheet: CallControlsHeightObserver {
    func callControlsHeightDidChange(newHeight: CGFloat) {
        self.setBottomSheetMinimizedHeight()
    }

    private enum HeightConstants {
        static let bottomPadding: CGFloat = 48
        static let initialTableInset: CGFloat = 25
    }
}
