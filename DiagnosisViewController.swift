//
//  DiagnosisViewController.swift
//  Viewer
//
//  Created by Mohammad Mainul Islam on 7/10/20.
//  Copyright © 2020 Occipital. All rights reserved.
//

import UIKit
import Structure

class DiagnosisViewController: UIViewController {
    
    @IBOutlet weak var infoLabel: UILabel!
    @IBOutlet weak var ulcerImageView: UIImageView!
    @IBOutlet weak var measureButton: UIButton!
    
    var ulcerImage: UIImage?
    
    let cropView = SECropView()
    
    @objc static func create(image: UIImage) ->  DiagnosisViewController {
        let storyboard = UIStoryboard(name: "Diagnosis", bundle: nil)
        let myVC = storyboard.instantiateViewController(withIdentifier: "DiagnosisVC") as! DiagnosisViewController
        myVC.ulcerImage = image
        return myVC
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        // Do any additional setup after loading the view.
        showImage(image: (ulcerImage?.normalized)!)
        
        cropView.configureWithCorners(corners: [CGPoint(x: 120, y: 100),
                                                CGPoint(x: 270, y: 170),
                                                CGPoint(x: 280, y: 450),
                                                CGPoint(x: 120, y: 400)], on: ulcerImageView)
    }
    
    func showImage(image: UIImage) {
        if let resized = image.resizeTo(width: ulcerImageView?.frame.width) {
            ulcerImageView.image = resized
        }
    }
    @IBAction func tapMeasureButton(_ sender: Any) {
        
        let ppm = UserDefaults.standard.float(forKey: "PPM")
        var distance = UserDefaults.standard.float(forKey: "distance")
        
        if let points = cropView.cornersLocationOnView {
            var width = CGPointDistance(from:points[0],  to: points[1]) * CGFloat(ppm)
            var length = CGPointDistance(from:points[0],  to: points[3]) * CGFloat(ppm)
            width = (width/100).rounded()
            length = (length/100).rounded()
            distance = (distance).rounded()
            print("Width: \(width) \n")
            print("Length: \(length) \n")
            let string = "PPM : \(ppm)   Distance: \(distance)cm   Width: \(width)cm   Length:\(length)cm"
            infoLabel.text = string
        }
        
    }
    
}

extension DiagnosisViewController {
    
    func CGPointDistanceSquared(from: CGPoint, to: CGPoint) -> CGFloat {
        return (from.x - to.x) * (from.x - to.x) + (from.y - to.y) * (from.y - to.y)
    }

    func CGPointDistance(from: CGPoint, to: CGPoint) -> CGFloat {
        return sqrt(CGPointDistanceSquared(from: from, to: to))
    }
}
