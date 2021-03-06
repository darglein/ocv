﻿/**
 * Copyright (c) 2017 Darius Rückert
 * Licensed under the MIT License.
 * See LICENSE file for more information.
 */

#include "cudaSift.h"
#include "matching.h"

#include "saiga/opencv/opencv.h"
#include "saiga/time/performanceMeasure.h"


namespace cudasift {

void detectedKeypointsTest(){
    std::vector<std::string> imageFiles = {
        "small.jpg",
        "medium.jpg",
        "big.jpg",
        "landscape_small.jpg",
        "landscape.jpg",
//        "100.png",
//        "100_2.png",
//        "100_3.png",
//        "425_34.png",
//        "420_109.png",
    };

#ifdef SIFT_PRINT_TIMINGS
    int iterations = 1;
#else
    int iterations = 50;
#endif


    for(auto str : imageFiles){


        //load image with opencv
        cv::Mat1f img = cv::imread("data/"+str,cv::IMREAD_GRAYSCALE);
        SiftImageType iv = Saiga::MatToImageView<float>(img);
        Saiga::CUDA::CudaImage<float> cimg(img.rows,img.cols,Saiga::iAlignUp(img.cols*sizeof(float),256));

        Saiga::CUDA::copyImage(iv,cimg,cudaMemcpyHostToDevice);

        cout << "Image " << str << " Size: " << cimg.cols << "x" << cimg.rows << " pitch " << cimg.pitchBytes << endl;

        //initialize sift and init memory. Note: this object can be used for multiple
        //images of the same size
        int maxFeatures = 10000;
        SIFT_CUDA sift(cimg.cols,cimg.rows,false,-1,maxFeatures,3,0.04,10,1.6);
        sift.initMemory();

        //extract keypoints and descriptors and store them in gpu memory
        thrust::device_vector<SiftPoint> keypoints(maxFeatures);
        thrust::device_vector<float> descriptors(maxFeatures * 128);
        int extractedPoints;


        Saiga::measureObject<Saiga::CUDA::CudaScopedTimer>(
                    "sift.compute",iterations, [&]()
        {
            extractedPoints = sift.compute(cimg, keypoints, descriptors);
        });



        //        cout << "Extracted " << extractedPoints << " keypoints in " << time << "ms." << endl;
        cout << "Extracted " << extractedPoints << " keypoints." << endl;

        //copy to host
//        thrust::host_vector<SiftPoint> hkeypoints(extractedPoints);
//        thrust::copy(keypoints.begin(),keypoints.begin()+extractedPoints,hkeypoints.begin());

        //convert to cvkeypoints
        std::vector<cv::KeyPoint> cvkeypoints;
//        sift.KeypointsToCV(hkeypoints,cvkeypoints);
        sift.downloadKeypoints(Saiga::array_view<SiftPoint>(keypoints).slice_n(0, extractedPoints), cvkeypoints);

        //create debug image
        cv::Mat output;
        img.convertTo(output,CV_8UC1);
        cv::drawKeypoints(output, cvkeypoints, output,cv::Scalar(0,255,0,0), cv::DrawMatchesFlags::DRAW_RICH_KEYPOINTS );

        cv::imwrite("out/"+str+".features.png",output);
        cout << endl;
        CUDA_SYNC_CHECK_ERROR();

    }
}


void matchTest(){
    std::vector<std::string> imageFiles1 = {
//        "small.jpg",
//        "medium.jpg",
//        "big.jpg",
//        "landscape_small.jpg",
//        "landscape.jpg",
        "100.png",
        "100_2.png",
        "100_3.png",
    };
    std::vector<std::string> imageFiles2 = {
//        "small.jpg",
//        "medium.jpg",
//        "big.jpg",
//        "landscape_small.jpg",
//        "landscape.jpg",

        "135.png",
        "135_2.png",
        "135_3.png",
    };
#ifdef SIFT_PRINT_TIMINGS
    int iterations = 1;
#else
    int iterations = 50;
#endif


    for(int i =0; i < (int)imageFiles1.size() ; ++i){

        //load image with opencv
        cv::Mat1f img1 = cv::imread("data/"+imageFiles1[i],cv::IMREAD_GRAYSCALE);
        cv::Mat1f img2 = cv::imread("data/"+imageFiles2[i],cv::IMREAD_GRAYSCALE);

        Saiga::CUDA::CudaImage<float> cimg1(img1.rows,img1.cols,Saiga::iAlignUp(img1.cols*sizeof(float),256));
        copyImage(Saiga::MatToImageView<float>(img1),cimg1,cudaMemcpyHostToDevice);

        Saiga::CUDA::CudaImage<float> cimg2(img2.rows,img2.cols,Saiga::iAlignUp(img2.cols*sizeof(float),256));
        copyImage(Saiga::MatToImageView<float>(img2),cimg2,cudaMemcpyHostToDevice);


        int maxFeatures = 10000;
        SIFT_CUDA sift(cimg1.cols,cimg1.rows,false,-1,maxFeatures,3,0.04,10,1.6);
        sift.initMemory();

        //extract keypoints and descriptors and store them in gpu memory
        thrust::device_vector<SiftPoint> keypoints1(maxFeatures), keypoints2(maxFeatures);
        thrust::device_vector<float> descriptors1(maxFeatures * 128), descriptors2(maxFeatures * 128);

        int extractedPoints1 = sift.compute(cimg1,keypoints1,descriptors1);
        int extractedPoints2 = sift.compute(cimg2,keypoints2,descriptors2);


        cout << "Match size: " << extractedPoints1 << "x" << extractedPoints2 << endl;

        MatchGPU matcher( std::max(extractedPoints1,extractedPoints2) );
        matcher.initMemory();

        int K = 4;
        thrust::device_vector<float> distances(extractedPoints1 * K);
        thrust::device_vector<int> indices(extractedPoints1 * K);


        Saiga::measureObject<Saiga::CUDA::CudaScopedTimer>(
                    "matcher.knnMatch",iterations, [&]()
        {
            matcher.knnMatch(Saiga::array_view<float>(descriptors1).slice_n(0, extractedPoints1 * 128),
                             Saiga::array_view<float>(descriptors2).slice_n(0, extractedPoints2 * 128),
                             distances, indices, K
                             );
        });


        //		cout << "knnMatch finished in " << time  << "ms." << endl;

        //copy to host
        thrust::host_vector<float> hdistances = distances;
        thrust::host_vector<int> hindices = indices;

        std::vector<cv::DMatch> cvmatches;
        //apply ratio test and convert to cv::DMatch
        for(int j = 0; j < extractedPoints1; ++j){
            float d1 = hdistances[j*K+0];
            float d2 = hdistances[j*K+1];
            if(d1 < 0.7f * d2){
                int id = hindices[j*K+0];
                cv::DMatch m;
                m.distance = d1;
                m.queryIdx = j;
                m.trainIdx = id;
                cvmatches.push_back(m);
            }
        }
        cout << "Number of good matches: " << cvmatches.size() << endl;


//        std::vector<SiftPoint> hkeypoints1(extractedPoints1), hkeypoints2(extractedPoints2);
//        thrust::copy(keypoints1.begin(),keypoints1.begin()+extractedPoints1,hkeypoints1.begin());
//        thrust::copy(keypoints2.begin(),keypoints2.begin()+extractedPoints2,hkeypoints2.begin());
        //convert to cvkeypoints
        std::vector<cv::KeyPoint> cvkeypoints1, cvkeypoints2;
        sift.downloadKeypoints(Saiga::array_view<SiftPoint>(keypoints1).slice_n(0, extractedPoints1), cvkeypoints1);
        sift.downloadKeypoints(Saiga::array_view<SiftPoint>(keypoints2).slice_n(0, extractedPoints2), cvkeypoints2);
//        sift.KeypointsToCV(hkeypoints1,cvkeypoints1);
//        sift.KeypointsToCV(hkeypoints2,cvkeypoints2);

        {
            cv::Mat img1 = cv::imread("data/"+imageFiles1[i]);
            cv::Mat img2 = cv::imread("data/"+imageFiles2[i]);
            //create debug match image
            cv::Mat outImg;
            //cv::drawMatches(img1,cvkeypoints1,img2,cvkeypoints2,cvmatches,outImg,cv::Scalar(0,0,255),cv::Scalar(0,255,0),std::vector<char>(),cv::DrawMatchesFlags::NOT_DRAW_SINGLE_POINTS);
            cv::drawMatches(img1,cvkeypoints1,img2,cvkeypoints2,cvmatches,outImg,cv::Scalar(0,255,0),cv::Scalar(0,255,0),std::vector<char>(),cv::DrawMatchesFlags::NOT_DRAW_SINGLE_POINTS);
            cv::imwrite("out/matches_"+imageFiles1[i]+"_"+imageFiles2[i]+".png",outImg);
        }

        cout << endl;
    }

}

}
