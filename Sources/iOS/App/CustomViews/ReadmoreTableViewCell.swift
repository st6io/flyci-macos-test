//
//  ReadmoreTableViewCell.swift
//  iMast
//
//  Created by rinsuki on 2018/07/28.
//  
//  ------------------------------------------------------------------------
//
//  Copyright 2017-2019 rinsuki and other contributors.
// 
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
// 
//      http://www.apache.org/licenses/LICENSE-2.0
// 
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.
//

import UIKit

class ReadmoreTableViewCell: UITableViewCell {
    enum State {
        case moreLoadable
        case allLoaded
        case loading
        case withError
    }
    
    var lastError: Error?
    
    let indicator = UIActivityIndicatorView()
    
    var state: State = .moreLoadable {
        didSet {
            DispatchQueue.mainSafeSync {
                self.textLabel?.isHidden = state == .loading
                if state == .loading {
                    self.indicator.startAnimating()
                } else {
                    self.indicator.stopAnimating()
                }
                self.selectionStyle = state != .moreLoadable ? .none : .gray
                if state != .loading {
                    let disabled = state == .allLoaded
                    let isError = state == .withError
                    self.textLabel?.text = disabled ? "ここまで" : isError ? "エラー" : "もっと"
                    self.textLabel?.textColor = disabled ? UIColor.lightGray : isError ? .systemRed : self.tintColor
                }
            }
        }
    }
    
    init() {
        super.init(style: .default, reuseIdentifier: nil)
        self.textLabel?.text = "もっと"
        self.textLabel?.textAlignment = .center
        self.textLabel?.textColor = self.tintColor
        self.selectionStyle = .gray
        self.addSubview(self.indicator)
        self.indicator.style = .medium
        self.indicator.hidesWhenStopped = true
        self.indicator.translatesAutoresizingMaskIntoConstraints = false
        self.indicator.centerXAnchor.constraint(equalTo: self.centerXAnchor).isActive = true
        self.indicator.centerYAnchor.constraint(equalTo: self.centerYAnchor).isActive = true
    }
    
    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func setSelected(_ selected: Bool, animated: Bool) {
        super.setSelected(selected, animated: animated)

        // Configure the view for the selected state
    }
    
    func readMoreTapped(viewController: UIViewController, next: () -> Void) {
        if self.state == .withError {
            if let error = self.lastError {
                viewController.errorReport(error: error)
            }
            self.state = .moreLoadable
        } else {
            next()
        }
    }
}